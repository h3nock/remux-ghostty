const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const testing = std.testing;
const assert = @import("../../quirks.zig").inlineAssert;
const size = @import("../../terminal/size.zig");
const CircBuf = @import("../../datastruct/main.zig").CircBuf;
const CursorStyle = @import("../../terminal/cursor.zig").Style;
const Screen = @import("../../terminal/Screen.zig");
const ScreenSet = @import("../../terminal/ScreenSet.zig");
const SharedTerminal = @import("../Shared.zig");
const Terminal = @import("../../terminal/Terminal.zig");
const TerminalStream = @import("../../terminal/stream_terminal.zig").Stream;
const mouse = @import("../../terminal/mouse.zig");
const RGB = @import("../../terminal/color.zig").RGB;
const Layout = @import("../../terminal/tmux/layout.zig").Layout;
const control = @import("control.zig");
const output = @import("output.zig");
const resize = @import("resize.zig");

const log = std.log.scoped(.terminal_tmux_viewer);

/// An incomplete UTF-8 sequence at the end of ignored hydration output.
/// A valid sequence can have at most three bytes before its final byte.
const Utf8Carry = struct {
    bytes: [3]u8 = undefined,
    len: u2 = 0,

    fn update(self: *Utf8Carry, data: []const u8) void {
        var tail: [6]u8 = undefined;
        var tail_len: usize = 0;

        if (data.len < self.bytes.len) {
            const carry = self.slice();
            @memcpy(tail[0..carry.len], carry);
            tail_len = carry.len;
        }

        const data_tail = data[data.len -| self.bytes.len..];
        @memcpy(tail[tail_len..][0..data_tail.len], data_tail);
        tail_len += data_tail.len;

        const suffix = incompleteUtf8Suffix(tail[0..tail_len]);
        @memcpy(self.bytes[0..suffix.len], suffix);
        self.len = @intCast(suffix.len);
    }

    fn slice(self: *const Utf8Carry) []const u8 {
        return self.bytes[0..self.len];
    }

    fn clear(self: *Utf8Carry) void {
        self.len = 0;
    }

    fn incompleteUtf8Suffix(data: []const u8) []const u8 {
        if (data.len == 0) return &.{};

        var start = data.len - 1;
        while (start > 0 and isContinuation(data[start])) start -= 1;

        const expected_len: usize = switch (data[start]) {
            0xC2...0xDF => 2,
            0xE0...0xEF => 3,
            0xF0...0xF4 => 4,
            else => return &.{},
        };
        const actual_len = data.len - start;
        if (actual_len >= expected_len) return &.{};
        for (data[start + 1 ..]) |byte| {
            if (!isContinuation(byte)) return &.{};
        }

        return data[start..];
    }

    fn isContinuation(byte: u8) bool {
        return byte >= 0x80 and byte <= 0xBF;
    }
};

/// Terminal state that must not affect replay of a captured grid.
const SnapshotReplayState = struct {
    modes: @FieldType(Terminal, "modes"),
    scrolling_region: Terminal.ScrollingRegion,

    fn begin(terminal: *Terminal) SnapshotReplayState {
        const saved: SnapshotReplayState = .{
            .modes = terminal.modes,
            .scrolling_region = terminal.scrolling_region,
        };
        terminal.modes.set(.insert, false);
        terminal.modes.set(.origin, false);
        terminal.modes.set(.linefeed, true);
        terminal.modes.set(.wraparound, true);
        terminal.modes.set(.enable_left_and_right_margin, false);
        terminal.scrolling_region = .{
            .top = 0,
            .bottom = terminal.rows - 1,
            .left = 0,
            .right = terminal.cols - 1,
        };
        return saved;
    }

    fn restore(self: SnapshotReplayState, terminal: *Terminal) void {
        terminal.modes = self.modes;
        terminal.scrolling_region = self.scrolling_region;
    }
};

// TODO: A list of TODOs as I think about them.
// - We need to make startup more robust so session and block can happen
//   out of order.
// - We should note what the active window pane is on the tmux side;
//   we can use this at least for initial focus.

// NOTE: There is some fragility here that can possibly break if tmux
// changes their implementation. In particular, the order of notifications
// and assurances about what is sent when are based on reading the tmux
// source code as of Dec, 2025. These aren't documented as fixed.
//
// I've tried not to depend on anything that seems like it'd change
// in the future. For example, it seems reasonable that command output
// always comes before session attachment. But, I am noting this here
// in case something breaks in the future we can consider it. We should
// be able to easily unit test all variations seen in the real world.

/// The initial capacity of the command queue. We dynamically resize
/// as necessary so the initial value isn't that important, but if we
/// want to feel good about it we should make it large enough to support
/// our most realistic use cases without resizing.
const COMMAND_QUEUE_INITIAL = 8;

/// A viewer is a tmux control mode client that attempts to create
/// a remote view of a tmux session, including providing the ability to send
/// new input to the session.
///
/// This is the primary use case for tmux control mode, but technically
/// tmux control mode clients can do anything a normal tmux client can do,
/// so the `control.zig` and other files in this folder are more general
/// purpose.
///
/// This struct helps move through a state machine of connecting to a tmux
/// session, negotiating capabilities, listing window state, etc.
///
/// ## Viewer Lifecycle
///
/// The viewer waits for tmux's initial response and session notification,
/// then enters its command queue. It queries the tmux version and the complete
/// window layout. Every newly discovered pane is hydrated by one ordered
/// command group:
///
/// ```
/// pane state -> primary history -> saved primary -> current screen -> pending
/// ```
///
/// Tmux returns one FIFO response block for each command. Output received
/// before a pane's final pending response is covered by the snapshots and is
/// not rendered independently. The pane becomes live only after its canonical
/// screen, cursors, modes, and retained VT parser state are restored.
///
/// ## Error Handling
///
/// At any point, if an unrecoverable error occurs or tmux sends `%exit`,
/// the viewer transitions to the `defunct` state and emits an `.exit` action.
///
/// ## Session Changes
///
/// When `%session-changed` is received during `command_queue` state, the
/// viewer resets itself completely: clears all windows/panes, emits an
/// empty windows action, and restarts the `list_windows` flow for the new
/// session.
///
pub const Viewer = struct {
    /// Oldest tmux release with every command required by pane hydration.
    pub const minimum_tmux_version = "3.1";

    /// I/O implementation used for all internal state.
    io: std.Io,

    /// Allocator used for all internal state.
    alloc: Allocator,

    options: Options,

    /// Current state of the state machine.
    state: State,

    /// The current session ID we're attached to.
    session_id: usize,

    /// The owned name of the current session.
    session_name: []const u8,

    /// The tmux server version string (e.g., "3.5a"). We capture this
    /// on startup because it will allow us to change behavior between
    /// versions as necessary.
    tmux_version: []const u8,

    /// Commands waiting for their FIFO-correlated response blocks.
    command_queue: CommandQueue,

    /// Commands at the front of `command_queue` that have been emitted but
    /// have not received their correlated completion yet.
    sent_command_count: usize,

    /// The windows in the current session.
    windows: std.ArrayList(Window),

    /// The panes in the current session, mapped by pane ID.
    panes: PanesMap,

    /// Incomplete UTF-8 prefixes received before their pane is discovered.
    untracked_utf8: std.AutoArrayHashMapUnmanaged(usize, Utf8Carry),

    /// The client resize waiting for its reply, and the newest size asked
    /// for since. One resize at a time keeps each reply bracketing exactly
    /// one tmux resize.
    resize_inflight: ?ResizeInflight = null,
    resize_pending: ?ClientSize = null,

    /// The arena used for the prior action allocated state. This contains
    /// the contents for the actions as well as the actions slice itself.
    action_arena: ArenaAllocator.State,

    /// A single action pre-allocated that we use for single-action
    /// returns (common). This ensures that we can never get allocation
    /// errors on single-action returns, especially those such as `.exit`.
    action_single: [1]Action,

    pub const CommandQueue = CircBuf(QueuedCommand, undefined);
    pub const PanesMap = std.AutoArrayHashMapUnmanaged(usize, *Pane);

    const ResizeInflight = struct {
        /// Owns `before`.
        arena: ArenaAllocator,
        before: []const resize.Sample = &.{},

        /// Panes whose output arrived while the resize was in flight. tmux
        /// sends each pane's output in order and holds a reply only behind
        /// output queued before it, so one pane's later output can pass the
        /// reply only while another pane's earlier output is still queued.
        /// That output also arrives before the reply. With output from at
        /// most one pane, nothing was reordered around the resize.
        output_panes: std.AutoArrayHashMapUnmanaged(usize, void) = .empty,

        failed: bool = false,

        fn deinit(self: *ResizeInflight, alloc: Allocator) void {
            self.output_panes.deinit(alloc);
            self.arena.deinit();
        }
    };

    pub const ClientSize = struct {
        columns: size.CellCountInt,
        rows: size.CellCountInt,
    };

    pub const Options = struct {
        /// Byte limit forwarded directly to each newly created pane Terminal's
        /// local scrollback. Zero disables retained scrollback. This is
        /// independent of `history_line_limit`, which controls the number of
        /// remote tmux history rows requested.
        max_scrollback: usize = 10_000,

        /// Maximum history rows requested when a pane is first discovered.
        /// Null captures all available history; zero skips the history
        /// capture. This is independent of Terminal's byte-based scrollback
        /// storage limit.
        history_line_limit: ?usize = null,

        /// Initial control-client grid reported before the first topology
        /// query. Null leaves sizing to tmux.
        initial_client_size: ?ClientSize = null,
    };

    pub const ExitReason = union(enum) {
        server_exit: []const u8,
        unsupported_version: []const u8,
        client_failure,
    };

    /// What a `pane_changed` action reports about the pane.
    pub const PaneChange = struct {
        pane_id: usize,

        /// The pane's program set synchronized output (mode 2026) and hasn't
        /// reset it, so the pane's renderer draws nothing new. The terminal
        /// has no clock: a hold whose reset never arrives, because the
        /// program died mid-frame or tmux dropped the output, lasts until
        /// the host ends it with `endRenderHold` after a timeout.
        render_hold: bool,

        /// Counts the holds the pane's output has begun. A hold that ends
        /// and begins again between two reports, even within one output, is
        /// a new hold, so a host timing holds starts its timeout again.
        render_hold_generation: u64,
    };

    pub const Action = union(enum) {
        /// Tmux has closed the control mode connection, we should end
        /// our viewer session in some way.
        exit: ExitReason,

        /// Send one explicit command group to tmux. Member text is already
        /// serialized without transport delimiters and is borrowed until the
        /// next Viewer input. Call `CommandGroup.write` to produce the exact
        /// tmux wire form when using Viewer without ControlClient.
        command: CommandGroup,

        /// Windows changed. This may add, remove or change windows. The
        /// caller is responsible for diffing the new window list against
        /// the prior one. Remember that for a given Viewer, window IDs
        /// are guaranteed to be stable. Additionally, tmux (as of Dec 2025)
        /// never reuses window IDs within a server process lifetime.
        windows: []const Window,

        /// A pane's canonical terminal became live or received live output.
        /// The pane exists in `Viewer.panes` and is already updated when this
        /// action is emitted.
        pane_changed: PaneChange,

        pub fn format(self: Action, writer: *std.Io.Writer) !void {
            const T = Action;
            const info = @typeInfo(T).@"union";

            try writer.writeAll(@typeName(T));
            if (info.tag_type) |TagType| {
                try writer.writeAll("{ .");
                try writer.writeAll(@tagName(@as(TagType, self)));
                try writer.writeAll(" = ");

                inline for (info.fields) |u_field| {
                    if (self == @field(TagType, u_field.name)) {
                        const value = @field(self, u_field.name);
                        switch (u_field.type) {
                            // Window embeds ArenaAllocator.State; dumping
                            // `{any}` walks freed/poisoned arena nodes.
                            []const Window => try writer.print("[{d} windows]", .{value.len}),
                            else => try writer.print("{any}", .{value}),
                        }
                    }
                }

                try writer.writeAll(" }");
            }
        }
    };

    pub const CommandGroup = struct {
        members: []const []const u8,

        /// Serialize one tmux command line: members joined by ` ; ` and one
        /// trailing newline. Member text itself never contains CR or LF.
        pub fn write(
            self: CommandGroup,
            writer: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            assert(self.members.len > 0);
            for (self.members, 0..) |member, i| {
                assert(member.len > 0);
                assert(std.mem.indexOfAny(u8, member, "\r\n") == null);
                if (i != 0) try writer.writeAll(" ; ");
                try writer.writeAll(member);
            }
            try writer.writeByte('\n');
        }
    };

    pub const CommandCompletion = union(enum) {
        success: []const u8,
        failure,
    };

    pub const Input = union(enum) {
        /// The implicit control-mode attach command completed successfully.
        handshake_ok,

        /// Completion of exactly one previously emitted command member.
        command_complete: CommandCompletion,

        /// Raw tmux input. This is retained as a thin adapter for callers
        /// using Viewer directly; ControlClient uses the canonical inputs.
        tmux: control.Notification,
    };

    pub const Window = struct {
        id: usize,
        name: []const u8,
        width: usize,
        height: usize,
        is_zoomed: bool,
        is_active: bool,
        active_pane_id: usize,
        layout_arena: ArenaAllocator.State,
        layout: Layout,
        visible_layout: Layout,

        pub fn deinit(self: *Window, alloc: Allocator) void {
            if (self.name.len > 0) alloc.free(self.name);
            self.layout_arena.promote(alloc).deinit();
        }
    };

    pub const Pane = struct {
        terminal_owner: *SharedTerminal,
        stream: TerminalStream,
        current_command: []const u8 = "",
        current_path: []const u8 = "",
        phase: Phase = .initial_hydrating,
        active_screen: ScreenSet.Key = .primary,
        has_history: bool = false,
        cursor: ?CursorPosition = null,
        saved_primary_cursor: ?CursorPosition = null,
        utf8_carry: Utf8Carry = .{},

        /// Output that arrived after tmux paused this pane for a recapture.
        /// It postdates the snapshot and is applied after it.
        replay: std.ArrayList(u8) = .empty,

        /// Whether output while `.refreshing` is kept for replay (a paused
        /// recapture) or already covered by the snapshot (tmux 3.1, which
        /// can't pause a pane).
        replay_output: bool = false,

        /// The replies of a recapture. The pane stays shown while it's
        /// recaptured, so they're applied together when the last arrives.
        snapshot: Snapshot = .{},

        /// `Terminal.region_rows_scrolled_out` when the mirror last matched
        /// tmux. A later scroll of a region below the top row put rows into
        /// tmux's history but not the mirror's, so rows pulled back by a
        /// resize would differ.
        region_rows_baseline: u64 = 0,

        /// The pane's window isn't shown and the mirror no longer matches
        /// tmux. It's recaptured when its window becomes active.
        stale: bool = false,

        /// Resized while the alternate screen was active. tmux keeps the
        /// normal screen at its old size until the program leaves the
        /// alternate screen, so the pane is recaptured then.
        primary_stale: bool = false,

        /// Rows of tmux's normal screen in the last snapshot taken while the
        /// alternate screen was active: the height tmux keeps it at until
        /// the program leaves.
        saved_primary_rows: usize = 0,

        /// The pane's size in tmux's latest layout. A live mirror of another
        /// size was resized by something other than a resize this Viewer
        /// sent, and can't follow it exactly.
        layout_cols: size.CellCountInt = 0,
        layout_rows: size.CellCountInt = 0,

        /// See `PaneChange.render_hold_generation`.
        render_hold_generation: u64 = 0,

        pub const Phase = enum {
            initial_hydrating,

            /// Waiting for tmux to pause this pane's output before a
            /// recapture. Output until then is covered by the snapshot.
            refresh_pausing,

            refreshing,
            live,
        };

        const CursorPosition = struct {
            x: size.CellCountInt,
            y: size.CellCountInt,

            /// tmux reports a cursor waiting to wrap at the right edge one
            /// column past the last; Ghostty keeps it on the last column.
            pending_wrap: bool = false,
        };

        const Snapshot = struct {
            parts: std.EnumArray(Part, ?[]u8) = .initFill(null),

            const Part = enum { state, history, saved_visible, visible };

            fn keep(
                self: *Snapshot,
                alloc: Allocator,
                part: Part,
                content: []const u8,
            ) Allocator.Error!void {
                const copy = try alloc.dupe(u8, content);
                if (self.parts.get(part)) |old| alloc.free(old);
                self.parts.set(part, copy);
            }

            fn deinit(self: *Snapshot, alloc: Allocator) void {
                for (&self.parts.values) |*part| {
                    if (part.*) |content| alloc.free(content);
                    part.* = null;
                }
            }
        };

        fn restoreCursor(screen: *Screen, position: ?CursorPosition) void {
            const pos = position orelse return;
            if (pos.x >= screen.pages.cols or pos.y >= screen.pages.rows) return;
            screen.cursorAbsolute(pos.x, pos.y);
            screen.cursor.pending_wrap = pos.pending_wrap;
        }

        fn init(
            io: std.Io,
            alloc: Allocator,
            terminal_opts: Terminal.Options,
        ) Allocator.Error!*Pane {
            const self = try alloc.create(Pane);
            errdefer alloc.destroy(self);

            const terminal_owner = try SharedTerminal.init(io, alloc, terminal_opts);
            errdefer terminal_owner.release();

            self.* = .{
                .terminal_owner = terminal_owner,
                .stream = terminalStream(&terminal_owner.terminal),
            };
            return self;
        }

        /// A stream over the pane's terminal that counts the holds its output
        /// begins. Whether a hold is on comes from the terminal's mode: the
        /// mirror's resizes and recaptures end holds without telling the
        /// stream.
        fn terminalStream(terminal: *Terminal) TerminalStream {
            var stream = terminal.vtStream();
            stream.handler.effects.render_hold = &renderHold;
            return stream;
        }

        fn renderHold(handler: *TerminalStream.Handler, held: bool) void {
            if (!held) return;
            const stream: *TerminalStream = @fieldParentPtr("handler", handler);
            const pane: *Pane = @fieldParentPtr("stream", stream);
            pane.render_hold_generation +%= 1;
        }

        /// The pane's report for a `pane_changed` action. The caller holds
        /// the pane's terminal lock.
        fn changeLocked(self: *const Pane, pane_id: usize) PaneChange {
            return .{
                .pane_id = pane_id,
                .render_hold = self.terminal_owner.terminal.modes.get(.synchronized_output),
                .render_hold_generation = self.render_hold_generation,
            };
        }

        fn change(self: *const Pane, pane_id: usize) PaneChange {
            const owner = self.terminal_owner;
            owner.mutex.lockUncancelable(owner.terminal.io());
            defer owner.mutex.unlock(owner.terminal.io());
            return self.changeLocked(pane_id);
        }

        /// End the pane's render hold, as a terminal's process runtime does
        /// when its timeout expires. Ending no hold changes nothing.
        pub fn endRenderHold(self: *Pane) void {
            const owner = self.terminal_owner;
            owner.mutex.lockUncancelable(owner.terminal.io());
            defer owner.mutex.unlock(owner.terminal.io());
            owner.terminal.modes.set(.synchronized_output, false);
        }

        /// Retain the pane's canonical terminal for use beyond this Pane's
        /// lifetime. The caller must release the returned owner.
        pub fn retainTerminal(self: *const Pane) *SharedTerminal {
            return self.terminal_owner.retain();
        }

        pub fn deinit(self: *Pane, alloc: Allocator) void {
            if (self.current_command.len > 0) alloc.free(self.current_command);
            if (self.current_path.len > 0) alloc.free(self.current_path);
            self.replay.deinit(alloc);
            self.snapshot.deinit(alloc);
            self.stream.deinit();
            self.terminal_owner.release();
            alloc.destroy(self);
        }
    };

    /// Initialize a new viewer.
    ///
    /// The given allocator is used for all internal state. You must
    /// call deinit when you're done with the viewer to free it.
    pub fn init(
        io: std.Io,
        alloc: Allocator,
        options: Options,
    ) Allocator.Error!Viewer {
        // Create our initial command queue
        var command_queue: CommandQueue = try .init(alloc, COMMAND_QUEUE_INITIAL);
        errdefer command_queue.deinit(alloc);

        return .{
            .io = io,
            .alloc = alloc,
            .options = options,
            .state = .startup_block,
            // The default value here is meaningless. We don't get started
            // until we receive a session-changed notification which will
            // set this to a real value.
            .session_id = 0,
            .session_name = "",
            .tmux_version = "",
            .command_queue = command_queue,
            .sent_command_count = 0,
            .windows = .empty,
            .panes = .empty,
            .untracked_utf8 = .empty,
            .action_arena = .{},
            .action_single = undefined,
        };
    }

    pub fn deinit(self: *Viewer) void {
        {
            for (self.windows.items) |*window| window.deinit(self.alloc);
            self.windows.deinit(self.alloc);
        }
        {
            var it = self.command_queue.iterator(.forward);
            while (it.next()) |queued| queued.command.deinit(self.alloc);
            self.command_queue.deinit(self.alloc);
        }
        {
            var it = self.panes.iterator();
            while (it.next()) |kv| kv.value_ptr.*.deinit(self.alloc);
            self.panes.deinit(self.alloc);
        }
        self.untracked_utf8.deinit(self.alloc);
        if (self.resize_inflight) |*inflight| inflight.deinit(self.alloc);
        if (self.session_name.len > 0) {
            self.alloc.free(self.session_name);
        }
        if (self.tmux_version.len > 0) {
            self.alloc.free(self.tmux_version);
        }
        self.action_arena.promote(self.alloc).deinit();
    }

    /// Rehydrate one live pane into its existing terminal. The caller owns
    /// tmux presentation policy and must enqueue any selection or layout
    /// command before this call. `submitter.submitPaneRefresh` is invoked
    /// synchronously after the pane enters the hydration barrier and must
    /// atomically enqueue the supplied semicolon-dependent command group.
    /// All access to Viewer and the submitter must be caller-serialized.
    pub fn refreshPane(
        self: *Viewer,
        pane_id: usize,
        submitter: anytype,
    ) !void {
        if (self.state != .command_queue) return error.NotReady;
        const pane = self.panes.get(pane_id) orelse return error.PaneUnknown;
        if (pane.phase != .live) return error.NotReady;

        // A recapture pauses the pane's output, which would void the
        // ordering a client resize relies on.
        if (self.resize_inflight != null) return error.NotReady;

        // ControlClient submits every Viewer group synchronously. Refusing a
        // refresh while a group is not yet submitted preserves one FIFO cut
        // between Viewer semantics and Channel framing.
        if (self.sent_command_count != self.command_queue.len()) {
            return error.NotReady;
        }

        var command_storage: [recapture_command_capacity]Command = undefined;
        const commands = self.recaptureCommands(pane_id, &command_storage);

        // The formatted members live only through the synchronous submit.
        // The arena is independent of the action arena because refresh is
        // also valid from a host action callback.
        var arena = ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        var members: [recapture_command_capacity][]const u8 = undefined;
        for (commands, 0..) |command, i| {
            var builder: std.Io.Writer.Allocating = .init(arena.allocator());
            command.formatCommand(&builder.writer) catch
                return error.OutOfMemory;
            members[i] = builder.writer.buffered();
        }

        // Reserve Viewer storage before changing the observable phase. The
        // Channel submit reserves all of its storage before mutation, so an
        // enqueue failure can restore the pane without a half-queued group.
        try self.command_queue.ensureUnusedCapacity(self.alloc, commands.len);
        const prior = pane.*;
        self.beginRecapture(pane);
        submitter.submitPaneRefresh(members[0..commands.len]) catch |err| {
            pane.phase = prior.phase;
            pane.utf8_carry = prior.utf8_carry;
            pane.stale = prior.stale;
            return err;
        };

        for (commands, 0..) |command, i| {
            self.command_queue.appendAssumeCapacity(.{
                .command = command,
                .group_end = i + 1 == commands.len,
                .refresh_pane_id = pane_id,
            });
        }
        self.sent_command_count += commands.len;
    }

    /// Resize the control client. When the reply arrives, tmux's resize of
    /// every pane is applied to its mirror with tmux's own row rules. While
    /// a resize or a recapture is in flight only the newest size is kept, and
    /// it's sent once they finish. `submitter.submitClientResize` must
    /// synchronously enqueue the supplied command group.
    pub fn setClientSize(
        self: *Viewer,
        client_size: ClientSize,
        submitter: anytype,
    ) !void {
        if (client_size.columns == 0 or client_size.rows == 0) return error.InvalidInput;
        switch (self.state) {
            .defunct => return error.NotReady,

            // Sent with the startup commands.
            .startup_block, .startup_session => {
                self.resize_pending = client_size;
                return;
            },

            .command_queue => {},
        }
        if (self.resize_inflight != null or self.recaptureInFlight()) {
            self.resize_pending = client_size;
            return;
        }
        if (self.sent_command_count != self.command_queue.len()) {
            return error.NotReady;
        }

        const commands = resizeCommands(client_size);
        var arena = ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        var members: [commands.len][]const u8 = undefined;
        for (commands, 0..) |command, i| {
            var builder: std.Io.Writer.Allocating = .init(arena.allocator());
            command.formatCommand(&builder.writer) catch
                return error.OutOfMemory;
            members[i] = builder.writer.buffered();
        }

        try self.command_queue.ensureUnusedCapacity(self.alloc, commands.len);
        try submitter.submitClientResize(&members);
        for (commands, 0..) |command, i| {
            self.command_queue.appendAssumeCapacity(.{
                .command = command,
                .group_end = i + 1 == commands.len,
            });
        }
        self.sent_command_count += commands.len;
        self.resize_inflight = .{ .arena = .init(self.alloc) };
        self.resize_pending = null;
    }

    fn resizeCommands(client_size: ClientSize) [3]Command {
        return .{
            .resize_sample_before,
            .{ .resize_client = client_size },
            .resize_sample_after,
        };
    }

    /// Queue a client resize from inside an input. It's emitted with that
    /// input's other commands.
    fn queueResize(self: *Viewer, client_size: ClientSize) Allocator.Error!void {
        const commands = resizeCommands(client_size);
        try self.command_queue.ensureUnusedCapacity(self.alloc, commands.len);
        for (commands, 0..) |command, i| {
            self.command_queue.appendAssumeCapacity(.{
                .command = command,
                .group_end = i + 1 == commands.len,
            });
        }
        self.resize_inflight = .{ .arena = .init(self.alloc) };
    }

    fn flushPendingResize(self: *Viewer) Allocator.Error!void {
        if (self.resize_inflight != null or self.recaptureInFlight()) return;
        const pending = self.resize_pending orelse return;
        self.resize_pending = null;
        try self.queueResize(pending);
    }

    fn recaptureInFlight(self: *const Viewer) bool {
        for (self.panes.values()) |pane| switch (pane.phase) {
            .refresh_pausing, .refreshing => return true,
            .initial_hydrating, .live => {},
        };
        return false;
    }

    /// A refresh state query, the hydration captures and a continue.
    const recapture_command_capacity = 6;

    /// The commands that start a recapture: a pause, whose reply sends the
    /// snapshot, or on tmux 3.1, which can't pause a pane, the snapshot
    /// itself.
    fn recaptureCommands(
        self: *const Viewer,
        pane_id: usize,
        storage: *[recapture_command_capacity]Command,
    ) []const Command {
        if (self.supportsPanePause()) {
            storage[0] = .{ .pane_pause = pane_id };
            return storage[0..1];
        }
        storage[0] = .{ .pane_refresh_state = pane_id };
        const hydration = self.paneHydrationCommands(pane_id, storage[1..]);
        return storage[0 .. hydration.len + 1];
    }

    fn beginRecapture(self: *const Viewer, pane: *Pane) void {
        pane.phase = if (self.supportsPanePause()) .refresh_pausing else .refreshing;
        pane.replay_output = false;
        pane.replay.clearRetainingCapacity();
        pane.snapshot.deinit(self.alloc);
        pane.utf8_carry.clear();
        pane.stale = false;
    }

    fn queueRecapture(self: *Viewer, pane_id: usize, pane: *Pane) Allocator.Error!void {
        var storage: [recapture_command_capacity]Command = undefined;
        const commands = self.recaptureCommands(pane_id, &storage);
        try self.command_queue.ensureUnusedCapacity(self.alloc, commands.len);
        self.beginRecapture(pane);
        for (commands, 0..) |command, i| {
            self.command_queue.appendAssumeCapacity(.{
                .command = command,
                .group_end = i + 1 == commands.len,
                .refresh_pane_id = pane_id,
            });
        }
    }

    /// tmux paused the pane. Nothing it sends for the pane from now on is in
    /// the snapshot, so it's kept and applied after it.
    fn receivedPanePaused(self: *Viewer, pane_id: usize) Allocator.Error!void {
        const pane = self.panes.get(pane_id) orelse return;
        if (pane.phase != .refresh_pausing) return;

        var storage: [recapture_command_capacity]Command = undefined;
        storage[0] = .{ .pane_refresh_state = pane_id };
        const hydration = self.paneHydrationCommands(pane_id, storage[1..]);
        storage[hydration.len + 1] = .{ .pane_continue = pane_id };
        const commands = storage[0 .. hydration.len + 2];

        try self.command_queue.ensureUnusedCapacity(self.alloc, commands.len);
        pane.phase = .refreshing;
        pane.replay_output = true;
        for (commands, 0..) |command, i| {
            self.command_queue.appendAssumeCapacity(.{
                .command = command,
                .group_end = i + 1 == commands.len,
                .refresh_pane_id = pane_id,
            });
        }
    }

    /// `refresh-client -A` exists from tmux 3.2.
    fn supportsPanePause(self: *const Viewer) bool {
        const version = parseTmuxVersion(self.tmux_version) orelse return false;
        return version.major > 3 or (version.major == 3 and version.minor >= 2);
    }

    /// Refresh the lightweight metadata for every pane in one known window.
    /// This does not enter a pane hydration barrier or capture terminal
    /// contents. The caller must synchronously enqueue the supplied command so
    /// Viewer and transport response ordering remain identical.
    pub fn refreshWindowPaneMetadata(
        self: *Viewer,
        window_id: usize,
        submitter: anytype,
    ) !void {
        if (self.state != .command_queue) return error.NotReady;
        for (self.windows.items) |window| {
            if (window.id == window_id) break;
        } else return error.WindowUnknown;

        const command: Command = .{ .pane_metadata = window_id };
        var builder: std.Io.Writer.Allocating = .init(self.alloc);
        defer builder.deinit();
        command.formatCommand(&builder.writer) catch
            return error.OutOfMemory;

        try self.command_queue.ensureUnusedCapacity(self.alloc, 1);
        try submitter.submitPaneMetadataRefresh(builder.writer.buffered());
        self.command_queue.appendAssumeCapacity(.{
            .command = command,
            .group_end = true,
        });
        self.sent_command_count += 1;
    }

    /// Send in an input event (such as a tmux protocol notification,
    /// keyboard input for a pane, etc.) and process it. The returned
    /// list is a set of actions to take as a result of the input prior
    /// to the next input. This list may be empty.
    pub fn next(self: *Viewer, input: Input) []const Action {
        // Developer note: this function must never return an error. If
        // an error occurs we must go into a defunct state or some other
        // state to gracefully handle it.
        return switch (input) {
            .handshake_ok => self.nextHandshakeOk(),
            .command_complete => |completion| self.nextCommandCompletion(completion),
            .tmux => self.nextTmux(input.tmux),
        };
    }

    fn nextHandshakeOk(self: *Viewer) []const Action {
        return switch (self.state) {
            .startup_block => handshake: {
                self.state = .startup_session;
                break :handshake &.{};
            },
            .defunct => &.{},
            .startup_session, .command_queue => self.defunct(),
        };
    }

    fn nextTmux(
        self: *Viewer,
        n: control.Notification,
    ) []const Action {
        return switch (self.state) {
            .defunct => defunct: {
                log.info("received notification in defunct state, ignoring", .{});
                break :defunct &.{};
            },

            .startup_block => self.nextStartupBlock(n),
            .startup_session => self.nextStartupSession(n),
            .command_queue => switch (n) {
                .block_end => |block| if (block.meta.isClient())
                    self.nextCommandCompletion(.{ .success = block.data })
                else
                    &.{},
                .block_err => |block| if (block.meta.isClient())
                    self.nextDirectCommandError()
                else
                    &.{},
                else => self.nextCommandNotification(n),
            },
        };
    }

    fn nextStartupBlock(
        self: *Viewer,
        n: control.Notification,
    ) []const Action {
        assert(self.state == .startup_block);

        switch (n) {
            // This is only sent by the DCS parser when we first get
            // DCS 1000p, it should never reach us here.
            .enter => unreachable,

            // I don't think this is technically possible (reading the
            // tmux source code), but if we see an exit we can semantically
            // handle this without issue.
            .exit => |detail| return self.defunctWith(.{
                .server_exit = detail,
            }),

            // The implicit attach response is always server-originated. A
            // client block here is unsolicited and must not advance startup.
            .block_end => |block| return if (block.meta.flags == 0)
                self.nextHandshakeOk()
            else
                self.defunct(),
            .block_err => return self.defunct(),

            // I don't like catch-all else branches but startup is such
            // a special case of looking for very specific things that
            // are unlikely to expand.
            else => return &.{},
        }
    }

    fn nextStartupSession(
        self: *Viewer,
        n: control.Notification,
    ) []const Action {
        assert(self.state == .startup_session);

        switch (n) {
            .enter => unreachable,

            .exit => |detail| return self.defunctWith(.{
                .server_exit = detail,
            }),

            .session_changed => |info| {
                const session_name = self.alloc.dupe(u8, info.name) catch {
                    log.warn("failed to retain session name, becoming defunct", .{});
                    return self.defunct();
                };

                var arena = self.action_arena.promote(self.alloc);
                defer self.action_arena = arena.state;
                _ = arena.reset(.free_all);

                const startup_size = self.resize_pending orelse self.options.initial_client_size;
                self.resize_pending = null;
                const commands: []const Command = if (startup_size) |client_size|
                    &.{ .tmux_version, .{ .client_size = client_size }, .list_windows }
                else
                    &.{ .tmux_version, .list_windows };
                const actions = self.enterCommandQueue(
                    arena.allocator(),
                    commands,
                ) catch {
                    self.alloc.free(session_name);
                    log.warn("failed to queue command, becoming defunct", .{});
                    return self.defunct();
                };

                self.session_id = info.id;
                self.session_name = session_name;
                return actions;
            },

            else => return &.{},
        }
    }

    fn nextCommandNotification(
        self: *Viewer,
        n: control.Notification,
    ) []const Action {
        assert(self.state == .command_queue);

        // If commands are queued between Viewer calls, their current group is
        // already in flight. Pane output therefore never needs to dispatch a
        // command and can bypass the action arena entirely. Active topology
        // notifications likewise update only Viewer-owned window state.
        var left_alternate: ?PaneChange = null;
        var shown_stale = false;
        switch (n) {
            .output => |out| {
                const result = self.receivedOutput(out) catch |err| {
                    log.warn(
                        "failed to process output for pane id={}, becoming defunct: {}",
                        .{ out.pane_id, err },
                    );
                    return self.defunct();
                };
                const changed = result orelse return &.{};
                if (!changed.recapture) {
                    return self.singleAction(.{ .pane_changed = changed.change });
                }
                left_alternate = changed.change;
            },
            .window_pane_changed => |info| return if (self.windowPaneChanged(
                info.window_id,
                info.pane_id,
            ))
                self.singleAction(.{ .windows = self.windows.items })
            else
                &.{},
            .session_window_changed => |info| {
                if (!self.sessionWindowChanged(info.session_id, info.window_id)) return &.{};
                if (!self.hasStaleShownPane()) {
                    return self.singleAction(.{ .windows = self.windows.items });
                }
                shown_stale = true;
            },
            .window_renamed => |info| {
                const changed = self.windowRenamed(info.id, info.name) catch {
                    log.warn("failed to retain window name, becoming defunct", .{});
                    return self.defunct();
                };
                return if (changed)
                    self.singleAction(.{ .windows = self.windows.items })
                else
                    &.{};
            },
            else => {},
        }

        // Clear our prior arena so it is ready to be used for any
        // actions immediately.
        {
            var arena = self.action_arena.promote(self.alloc);
            _ = arena.reset(.free_all);
            self.action_arena = arena.state;
        }

        // Setup our empty actions list that commands can populate.
        var actions: std.ArrayList(Action) = .empty;

        // A pane left the alternate screen after a resize, or a window with
        // out-of-date panes became visible: recapture them.
        if (left_alternate != null or shown_stale) {
            {
                var arena = self.action_arena.promote(self.alloc);
                defer self.action_arena = arena.state;
                const action: Action = if (left_alternate) |change|
                    .{ .pane_changed = change }
                else
                    .{ .windows = self.windows.items };
                actions.append(arena.allocator(), action) catch return self.defunct();
            }
            self.recaptureStaleShownPanes() catch return self.defunct();
            self.appendQueuedCommandActions(&actions) catch return self.defunct();
            return actions.items;
        }

        switch (n) {
            .enter => unreachable,
            .exit => |detail| return self.defunctWith(.{
                .server_exit = detail,
            }),

            .block_end, .block_err => unreachable,

            .output,
            .window_pane_changed,
            .session_window_changed,
            .window_renamed,
            => unreachable,

            // Session changed means we switched to a different tmux session.
            // We need to reset our state and start fresh with list-windows.
            // This completely replaces the viewer, so treat it like a fresh start.
            .session_changed => |info| {
                // Supported tmux releases queue this notification after the
                // response blocks of every command that preceded the session
                // switch. Replacing Viewer with outstanding semantic commands
                // would silently destroy FIFO correlation, so fail closed if
                // a future server violates that ordering.
                if (self.sent_command_count != 0 or !self.command_queue.empty()) {
                    log.warn(
                        "session changed with pending commands, becoming defunct sent={} queued={}",
                        .{ self.sent_command_count, self.command_queue.len() },
                    );
                    return self.defunct();
                }
                self.sessionChanged(
                    &actions,
                    info.id,
                    info.name,
                ) catch {
                    log.warn("failed to handle session change, becoming defunct", .{});
                    return self.defunct();
                };
            },

            // Layout changed of a single window.
            .layout_change => |info| self.layoutChanged(
                &actions,
                info.window_id,
                info.layout,
                info.visible_layout,
            ) catch {
                // Note: in the future, we can probably handle a failure
                // here with a fallback to remove this one window, list
                // windows again, and try again.
                log.warn("failed to handle layout change, becoming defunct", .{});
                return self.defunct();
            },

            // A window was added to this session.
            .window_add => |info| self.windowAdd(info.id) catch {
                log.warn("failed to handle window add, becoming defunct", .{});
                return self.defunct();
            },

            // Another session unlinked a window that is still linked here.
            .window_close => {},

            // This session no longer links the window. Removing known state
            // is local and idempotent because duplicate notifications are
            // normal tmux behavior.
            .unlinked_window_close => |info| self.unlinkedWindowClosed(
                &actions,
                info.id,
            ) catch {
                log.warn("failed to remove unlinked window, becoming defunct", .{});
                return self.defunct();
            },

            // We ignore this one. It means a session was created or
            // destroyed. If it was our own session we will get an exit
            // notification very soon. If it is another session we don't
            // care.
            .sessions_changed => {},

            // This window is not linked to our current session.
            .unlinked_window_renamed => {},

            // This is for other clients, which we don't do anything about.
            // For us, we'll get `exit` or `session_changed`, respectively.
            .client_detached,
            .client_session_changed,
            => {},
        }

        if (self.state == .command_queue) {
            self.appendQueuedCommandActions(&actions) catch return self.defunct();
        }

        return actions.items;
    }

    fn windowPaneChanged(
        self: *Viewer,
        window_id: usize,
        pane_id: usize,
    ) bool {
        for (self.windows.items) |*window| {
            if (window.id != window_id) continue;
            if (window.active_pane_id == pane_id) return false;
            window.active_pane_id = pane_id;
            return true;
        }
        return false;
    }

    fn sessionWindowChanged(
        self: *Viewer,
        session_id: usize,
        window_id: usize,
    ) bool {
        if (session_id != self.session_id) return false;

        for (self.windows.items) |window| {
            if (window.id == window_id) break;
        } else return false;

        var changed = false;
        for (self.windows.items) |*window| {
            const is_active = window.id == window_id;
            if (window.is_active == is_active) continue;
            window.is_active = is_active;
            changed = true;
        }
        return changed;
    }

    fn windowRenamed(
        self: *Viewer,
        window_id: usize,
        name: []const u8,
    ) Allocator.Error!bool {
        for (self.windows.items) |*window| {
            if (window.id != window_id) continue;
            if (std.mem.eql(u8, window.name, name)) return false;

            const retained: []const u8 = if (name.len == 0)
                ""
            else
                try self.alloc.dupe(u8, name);
            if (window.name.len > 0) self.alloc.free(window.name);
            window.name = retained;
            return true;
        }
        return false;
    }

    fn nextCommandCompletion(
        self: *Viewer,
        completion: CommandCompletion,
    ) []const Action {
        if (self.state == .defunct) return &.{};
        if (self.state != .command_queue) return self.defunct();

        self.resetActionArena();
        var actions: std.ArrayList(Action) = .empty;
        const exit_reason = self.receivedCommandCompletion(
            &actions,
            completion,
        ) catch |err| {
            log.warn("failed to process command completion, becoming defunct: {}", .{err});
            return self.defunct();
        };
        if (exit_reason) |reason| return self.defunctWith(reason);
        self.appendQueuedCommandActions(&actions) catch return self.defunct();
        return actions.items;
    }

    /// Raw tmux emits only one `%error` block for a failed command group.
    /// Consume the failed member and the remaining members of that same group
    /// as failures. The canonical ControlClient path receives those as
    /// separate correlated completion events from Channel instead.
    fn nextDirectCommandError(self: *Viewer) []const Action {
        if (self.sent_command_count == 0 or self.command_queue.empty()) {
            log.warn("unexpected client error block, becoming defunct", .{});
            return self.defunct();
        }

        self.resetActionArena();
        var actions: std.ArrayList(Action) = .empty;
        var terminal_failure = false;
        while (true) {
            const ends_group = self.command_queue.first().?.group_end;
            _ = self.receivedCommandCompletion(&actions, .failure) catch |err| switch (err) {
                error.CommandFailed, error.HydrationFailed => terminal_failure = true,
                else => {
                    log.warn("failed to process command error, becoming defunct: {}", .{err});
                    return self.defunct();
                },
            };
            if (ends_group) break;
        }

        if (terminal_failure) return self.defunct();
        self.appendQueuedCommandActions(&actions) catch return self.defunct();
        return actions.items;
    }

    fn resetActionArena(self: *Viewer) void {
        var arena = self.action_arena.promote(self.alloc);
        _ = arena.reset(.free_all);
        self.action_arena = arena.state;
    }

    /// When the layout changes for a single window, a pane may be added
    /// or removed that we've never seen, in addition to the layout itself
    /// physically changing.
    ///
    /// To handle this, its similar to list-windows except we expect the
    /// window to already exist. We update the layout, do the initLayout
    /// call for any diffs, setup commands to capture any new panes,
    /// prune any removed panes.
    fn layoutChanged(
        self: *Viewer,
        actions: *std.ArrayList(Action),
        window_id: usize,
        layout_str: []const u8,
        visible_layout_str: []const u8,
    ) !void {
        // Find the window this layout change is for.
        const window: *Window = window: for (self.windows.items) |*w| {
            if (w.id == window_id) break :window w;
        } else {
            log.info("layout change for unknown window id={}", .{window_id});
            return;
        };
        try self.setWindowLayout(window, layout_str, visible_layout_str);

        // Reset our arena so we can build up actions.
        var arena = self.action_arena.promote(self.alloc);
        defer self.action_arena = arena.state;
        const arena_alloc = arena.allocator();

        // Our initial action is to definitely let the caller know that
        // some windows changed.
        try actions.append(arena_alloc, .{ .windows = self.windows.items });

        // Sync up our panes
        try self.syncLayouts(self.windows.items);
        try self.afterTopologyChange();
    }

    /// Replace a window's layout, parsing both topology and canonical visible
    /// geometry from the same pair of layout strings.
    fn setWindowLayout(
        self: *Viewer,
        window: *Window,
        layout_str: []const u8,
        visible_layout_str: []const u8,
    ) !void {
        var arena = window.layout_arena.promote(self.alloc);
        defer window.layout_arena = arena.state;
        _ = arena.reset(.retain_capacity);
        const layout = Layout.parseWithChecksum(
            arena.allocator(),
            layout_str,
        ) catch |err| {
            log.info(
                "failed to parse window layout id={} layout={s}",
                .{ window.id, layout_str },
            );
            return err;
        };
        const is_zoomed = !std.mem.eql(u8, layout_str, visible_layout_str);
        const visible_layout = if (is_zoomed)
            Layout.parseWithChecksum(
                arena.allocator(),
                visible_layout_str,
            ) catch |err| {
                log.info(
                    "failed to parse visible window layout id={} layout={s}",
                    .{ window.id, visible_layout_str },
                );
                return err;
            }
        else
            layout;
        const active_pane_id = if (is_zoomed) switch (visible_layout.content) {
            .pane => |id| id,
            .horizontal, .vertical => return error.InvalidVisibleLayout,
        } else window.active_pane_id;
        window.width = layout.width;
        window.height = layout.height;
        window.is_zoomed = is_zoomed;
        window.active_pane_id = active_pane_id;
        window.layout = layout;
        window.visible_layout = visible_layout;
    }

    /// When a window is added to the session, we need to refresh our window
    /// list to get the new window's information.
    fn windowAdd(
        self: *Viewer,
        window_id: usize,
    ) !void {
        _ = window_id; // We refresh all windows via list-windows

        // Queue list-windows to get the updated window list
        try self.queueCommands(&.{.list_windows});
    }

    fn unlinkedWindowClosed(
        self: *Viewer,
        actions: *std.ArrayList(Action),
        window_id: usize,
    ) !void {
        const index = for (self.windows.items, 0..) |window, i| {
            if (window.id == window_id) break i;
        } else return;

        var arena = self.action_arena.promote(self.alloc);
        defer self.action_arena = arena.state;
        try actions.ensureUnusedCapacity(arena.allocator(), 1);

        var removed = self.windows.orderedRemove(index);
        errdefer self.windows.insertAssumeCapacity(index, removed);
        try self.syncLayouts(self.windows.items);

        removed.deinit(self.alloc);
        actions.appendAssumeCapacity(.{ .windows = self.windows.items });
        try self.afterTopologyChange();
    }

    fn syncLayouts(
        self: *Viewer,
        windows: []const Window,
    ) !void {
        // Go through the window layout and setup all our panes. We move
        // this into a new panes map so that we can easily prune our old
        // list.
        var panes: PanesMap = .empty;
        errdefer {
            // Clear out all the new panes.
            var panes_it = panes.iterator();
            while (panes_it.next()) |kv| {
                if (!self.panes.contains(kv.key_ptr.*)) {
                    kv.value_ptr.*.deinit(self.alloc);
                }
            }
            panes.deinit(self.alloc);
        }
        for (windows) |window| {
            var visible_found = false;
            const visible_pane: ?PaneGeometry = if (window.is_zoomed) switch (window.visible_layout.content) {
                .pane => |id| .{
                    .id = id,
                    .width = window.visible_layout.width,
                    .height = window.visible_layout.height,
                },
                .horizontal, .vertical => return error.InvalidVisibleLayout,
            } else null;

            try initLayout(
                self.io,
                self.alloc,
                &self.panes,
                &panes,
                window.layout,
                self.options.max_scrollback,
                visible_pane,
                &visible_found,
            );
            if (visible_pane != null and !visible_found) {
                return error.InvalidVisibleLayout;
            }
        }

        // Build up the list of removed panes.
        var removed: std.ArrayList(usize) = removed: {
            var removed: std.ArrayList(usize) = .empty;
            errdefer removed.deinit(self.alloc);
            var panes_it = self.panes.iterator();
            while (panes_it.next()) |kv| {
                if (panes.contains(kv.key_ptr.*)) continue;
                try removed.append(self.alloc, kv.key_ptr.*);
            }

            break :removed removed;
        };
        defer removed.deinit(self.alloc);

        // Ensure we can add the windows
        try self.windows.ensureTotalCapacity(self.alloc, windows.len);

        // Hydrate all newly discovered panes in one explicit command group.
        // Reserve exactly once before changing the queue.
        var added_count: usize = 0;
        {
            var panes_it = panes.iterator();
            while (panes_it.next()) |kv| {
                if (!self.panes.contains(kv.key_ptr.*)) added_count += 1;
            }
        }
        if (added_count > 0) {
            var count_storage: [4]Command = undefined;
            const commands_per_pane = self.paneHydrationCommands(
                0,
                &count_storage,
            ).len;
            const command_count = 1 + commands_per_pane * added_count;
            try self.command_queue.ensureUnusedCapacity(self.alloc, command_count);
            self.command_queue.appendAssumeCapacity(.{
                .command = .pane_state,
                .group_end = false,
            });

            var added_index: usize = 0;
            var panes_it = panes.iterator();
            while (panes_it.next()) |kv| {
                const pane_id = kv.key_ptr.*;
                if (self.panes.contains(pane_id)) continue;
                added_index += 1;

                var hydration_storage: [4]Command = undefined;
                const hydration = self.paneHydrationCommands(
                    pane_id,
                    &hydration_storage,
                );
                for (hydration, 0..) |command, command_index| {
                    self.command_queue.appendAssumeCapacity(.{
                        .command = command,
                        .group_end = added_index == added_count and
                            command_index + 1 == hydration.len,
                    });
                }
            }
        }

        // Transfer only the bounded UTF-8 suffixes that belong to newly
        // discovered panes in this topology snapshot.
        {
            var panes_it = panes.iterator();
            while (panes_it.next()) |kv| {
                if (self.panes.contains(kv.key_ptr.*)) continue;
                if (self.untracked_utf8.fetchSwapRemove(kv.key_ptr.*)) |entry| {
                    kv.value_ptr.*.utf8_carry = entry.value;
                }
            }
        }

        // No more errors after this point. We're about to replace all
        // our owned state with our temporary state, and our errdefers
        // above will double-free if there is an error.
        errdefer comptime unreachable;

        // Replace our window list if it changed. We assume it didn't
        // change if our pointer is pointing to the same data.
        if (windows.ptr != self.windows.items.ptr) {
            for (self.windows.items) |*window| window.deinit(self.alloc);
            self.windows.clearRetainingCapacity();
            self.windows.appendSliceAssumeCapacity(windows);
        }

        // Replace our panes
        {
            // First remove our old panes
            for (removed.items) |id| if (self.panes.fetchSwapRemove(
                id,
            )) |entry_const| {
                entry_const.value.deinit(self.alloc);
            };
            // We can now deinit self.panes because the existing
            // entries are preserved.
            self.panes.deinit(self.alloc);
            self.panes = panes;
        }
    }

    /// Live mirrors whose size differs from tmux's layout were resized by
    /// something other than a resize this Viewer sent. Their geometry
    /// follows the layout and their contents are recaptured.
    fn reconcileGeometry(self: *Viewer) Terminal.ResizeError!void {
        if (self.resize_inflight != null) return;
        for (self.panes.values()) |pane| {
            if (pane.phase != .live or pane.layout_cols == 0) continue;
            const owner = pane.terminal_owner;
            owner.mutex.lockUncancelable(owner.terminal.io());
            defer owner.mutex.unlock(owner.terminal.io());
            const t = &owner.terminal;
            if (t.cols == pane.layout_cols and t.rows == pane.layout_rows) continue;
            try t.resize(self.alloc, .{ .cols = pane.layout_cols, .rows = pane.layout_rows });
            pane.stale = true;
            if (t.screens.active_key == .alternate) pane.primary_stale = true;
        }
    }

    fn recaptureStaleShownPanes(self: *Viewer) Allocator.Error!void {
        if (self.resize_inflight != null) return;
        var it = self.panes.iterator();
        while (it.next()) |kv| {
            const pane = kv.value_ptr.*;
            if (!pane.stale or pane.phase != .live) continue;
            if (!self.paneShown(kv.key_ptr.*)) continue;
            try self.queueRecapture(kv.key_ptr.*, pane);
        }
    }

    fn hasStaleShownPane(self: *const Viewer) bool {
        var it = self.panes.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.*.stale and self.paneShown(kv.key_ptr.*)) return true;
        }
        return false;
    }

    /// Whether the pane is in the session's current window.
    fn paneShown(self: *const Viewer, pane_id: usize) bool {
        for (self.windows.items) |window| {
            if (window.is_active) return layoutContains(window.layout, pane_id);
        }
        return false;
    }

    fn layoutContains(layout: Layout, pane_id: usize) bool {
        return switch (layout.content) {
            .pane => |id| id == pane_id,
            .horizontal, .vertical => |children| for (children) |child| {
                if (layoutContains(child, pane_id)) break true;
            } else false,
        };
    }

    fn afterTopologyChange(self: *Viewer) !void {
        try self.reconcileGeometry();
        try self.recaptureStaleShownPanes();

        // A removed pane may have been the recapture a pending resize waited
        // for.
        try self.flushPendingResize();
    }

    fn parseResizeSamples(
        alloc: Allocator,
        content: []const u8,
    ) ![]const resize.Sample {
        var samples: std.ArrayList(resize.Sample) = .empty;
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line_raw| {
            const line = std.mem.trimEnd(u8, line_raw, "\r");
            if (line.len == 0) continue;
            const data = output.parseFormatStruct(
                Format.resize_sample.Struct(),
                line,
                Format.resize_sample.delim,
            ) catch |err| {
                log.info("failed to parse resize sample line: {s}", .{line});
                return err;
            };
            try samples.append(alloc, .{
                .pane_id = data.pane_id,
                .width = data.pane_width,
                .height = data.pane_height,
                .cursor_x = data.cursor_x,
                .cursor_y = data.cursor_y,
                .history = data.history_size,
                .alternate = data.alternate_on,
                .layout = try alloc.dupe(u8, data.window_layout),
                .visible_layout = try alloc.dupe(u8, data.window_visible_layout),
            });
        }
        return samples.items;
    }

    fn finishResize(
        self: *Viewer,
        arena_alloc: Allocator,
        actions: *std.ArrayList(Action),
        after_content: ?[]const u8,
    ) !void {
        var inflight = self.resize_inflight orelse return;
        self.resize_inflight = null;
        defer inflight.deinit(self.alloc);

        if (after_content) |content| if (!inflight.failed) {
            try self.applyResize(arena_alloc, actions, &inflight, content);
        };
        try self.afterTopologyChange();
    }

    fn applyResize(
        self: *Viewer,
        arena_alloc: Allocator,
        actions: *std.ArrayList(Action),
        inflight: *const ResizeInflight,
        content: []const u8,
    ) !void {
        const after_samples = try parseResizeSamples(arena_alloc, content);

        // tmux sends each window's %layout-change after this reply. Until
        // then a window would keep its old layout, and the notification for
        // another window would size this window's panes back to it.
        var windows_changed = false;
        for (self.windows.items) |*window| {
            const sample = for (after_samples) |sample| {
                if (sample.layout.len > 0 and layoutContains(window.layout, sample.pane_id)) break sample;
            } else continue;
            const visible = if (sample.visible_layout.len > 0) sample.visible_layout else sample.layout;
            try self.setWindowLayout(window, sample.layout, visible);
            windows_changed = true;
        }
        if (windows_changed) {
            // A command read together with a split runs before tmux notifies
            // the split, so the samples can hold a pane this viewer hasn't
            // seen. Adopting the layouts as a layout change does keeps every
            // published pane tracked, a new one behind its hydration.
            try self.syncLayouts(self.windows.items);
            try actions.append(arena_alloc, .{ .windows = self.windows.items });
        }

        const reordered = inflight.output_panes.count() > 1;
        for (after_samples) |after| {
            const pane = self.panes.get(after.pane_id) orelse continue;
            if (pane.phase != .live) continue;
            const cols = std.math.cast(size.CellCountInt, after.width) orelse
                return error.InvalidPaneGeometry;
            const rows = std.math.cast(size.CellCountInt, after.height) orelse
                return error.InvalidPaneGeometry;
            if (cols == 0 or rows == 0) return error.InvalidPaneGeometry;
            pane.layout_cols = cols;
            pane.layout_rows = rows;

            const before = for (inflight.before) |sample| {
                if (sample.pane_id == after.pane_id) break sample;
            } else null;
            const outcome: PaneResize = if (before) |b|
                try self.resizePane(
                    pane,
                    b,
                    after,
                    reordered and inflight.output_panes.contains(after.pane_id),
                )
            else
                .mismatch;

            switch (outcome) {
                .unchanged => {},
                .applied => try actions.append(arena_alloc, .{
                    .pane_changed = pane.change(after.pane_id),
                }),
                .mismatch => {
                    // Keep the geometry current; the contents are recaptured
                    // once the pane is shown.
                    const owner = pane.terminal_owner;
                    owner.mutex.lockUncancelable(owner.terminal.io());
                    defer owner.mutex.unlock(owner.terminal.io());
                    try owner.terminal.resize(self.alloc, .{ .cols = cols, .rows = rows });
                    pane.stale = true;
                    try actions.append(arena_alloc, .{
                        .pane_changed = pane.changeLocked(after.pane_id),
                    });
                },
            }
        }
    }

    const PaneResize = enum { unchanged, applied, mismatch };

    /// Repeat tmux's resize of one pane on its mirror.
    fn resizePane(
        self: *Viewer,
        pane: *Pane,
        before: resize.Sample,
        after: resize.Sample,
        reordered: bool,
    ) !PaneResize {
        const p = try resize.plan(self.alloc, before, after) orelse return .mismatch;
        if (p.len == 0) return .unchanged;
        if (pane.stale or reordered) return .mismatch;

        const owner = pane.terminal_owner;
        owner.mutex.lockUncancelable(owner.terminal.io());
        defer owner.mutex.unlock(owner.terminal.io());
        const t = &owner.terminal;

        // The mirror must be where tmux was when the resize ran.
        if (t.cols != before.width or t.rows != before.height) return .mismatch;
        if ((t.screens.active_key == .alternate) != before.alternate) return .mismatch;
        if (!resize.cursorMatches(t, before.cursor_x, before.cursor_y)) return .mismatch;
        if (p.pulled() > 0 and t.region_rows_scrolled_out != pane.region_rows_baseline) {
            return .mismatch;
        }
        if (!resize.canApply(t, &p)) return .mismatch;

        if (!try resize.apply(self.alloc, t, &p)) return .mismatch;
        if (!resize.cursorMatches(t, after.cursor_x, after.cursor_y)) return .mismatch;
        if (before.alternate) pane.primary_stale = true;
        return .applied;
    }

    /// When a session changes, we have to basically reset our whole state.
    /// To do this, we emit an empty windows event (so callers can clear all
    /// windows), reset ourself, and start all over.
    fn sessionChanged(
        self: *Viewer,
        actions: *std.ArrayList(Action),
        session_id: usize,
        session_name: []const u8,
    ) (Allocator.Error || std.Io.Writer.Error)!void {
        // Build up a new viewer. Its the easiest way to reset ourselves.
        var replacement: Viewer = try .init(self.io, self.alloc, self.options);
        errdefer replacement.deinit();

        replacement.session_name = try replacement.alloc.dupe(
            u8,
            session_name,
        );
        replacement.session_id = session_id;

        // Our actions must start out empty so we don't mix arenas
        assert(actions.items.len == 0);
        errdefer actions.* = .empty;

        // Build actions: empty windows notification + list-windows command
        var arena = replacement.action_arena.promote(replacement.alloc);
        const arena_alloc = arena.allocator();
        try actions.append(arena_alloc, .{ .windows = &.{} });

        // Setup our command queue and put ourselves in the command queue
        // state.
        try replacement.queueCommands(&.{.list_windows});
        replacement.state = .command_queue;

        // Transfer preserved version to replacement
        replacement.tmux_version = try replacement.alloc.dupe(u8, self.tmux_version);

        // Save arena state back before swap
        replacement.action_arena = arena.state;

        // Swap our self, no more error handling after this.
        errdefer comptime unreachable;
        self.deinit();
        self.* = replacement;

        assert(self.state == .command_queue);
    }

    fn receivedCommandCompletion(
        self: *Viewer,
        actions: *std.ArrayList(Action),
        completion: CommandCompletion,
    ) !?ExitReason {
        if (self.sent_command_count == 0) return error.UnexpectedCommandCompletion;

        // Get the command we're expecting output for. We need to get the
        // non-pointer value because we are deleting it from the circular
        // buffer immediately. This shallow copy is all we need since
        // all the memory in Command is owned by GPA.
        const queued = self.command_queue.first() orelse
            return error.UnexpectedCommandCompletion;
        const refresh_pane_id = queued.refresh_pane_id;
        const command: Command = switch (queued.command) {
            // I truly can't explain this. A simple `ptr.*` copy will cause
            // our memory to become undefined when deleteOldest is called
            // below. I logged all the pointers and they don't match so I
            // don't know how its being set to undefined. But a copy like
            // this does work.
            inline else => |v, tag| @unionInit(
                Command,
                @tagName(tag),
                v,
            ),
        };
        self.command_queue.deleteOldest(1);
        self.sent_command_count -= 1;
        defer command.deinit(self.alloc);

        const content = switch (completion) {
            .success => |body| body,
            .failure => {
                // A refresh targets an already-published pane. A capture can
                // fail if that pane disappears while the group is in flight;
                // keep the rest of the client alive and leave the pane behind
                // the hydration barrier until authoritative topology removes
                // it. Channel supplies failures for every skipped member, so
                // FIFO correlation remains intact without emitting a false
                // pane-changed completion.
                if (refresh_pane_id != null) return null;
                if (command.isHydration()) return error.HydrationFailed;
                switch (command) {
                    .pane_metadata, .user => return null,

                    // tmux skips the rest of a group after a failed member,
                    // so the after sample always reports the outcome.
                    .resize_sample_before, .resize_client => {
                        if (self.resize_inflight) |*inflight| inflight.failed = true;
                        return null;
                    },
                    .resize_sample_after => {
                        var arena = self.action_arena.promote(self.alloc);
                        defer self.action_arena = arena.state;
                        try self.finishResize(arena.allocator(), actions, null);
                        return null;
                    },
                    else => return error.CommandFailed,
                }
            },
        };

        // We'll use our arena for the return value here so we can
        // easily accumulate actions.
        var arena = self.action_arena.promote(self.alloc);
        defer self.action_arena = arena.state;
        const arena_alloc = arena.allocator();

        // Process our command
        switch (command) {
            .user => {},

            .pane_state => if (try self.receivedPaneState(null, content)) {
                try actions.append(arena_alloc, .{ .windows = self.windows.items });
            },

            .pane_refresh_state => |id| if (try self.receivedPaneState(id, content)) {
                try actions.append(arena_alloc, .{ .windows = self.windows.items });
            },

            .pane_metadata => if (try self.receivedPaneMetadata(content)) {
                try actions.append(arena_alloc, .{ .windows = self.windows.items });
            },

            .list_windows => try self.receivedListWindows(
                arena_alloc,
                actions,
                content,
            ),

            .pane_history => |capture| try self.receivedPaneHistory(capture.id, content),

            .pane_saved_visible => |id| try self.receivedPaneSavedVisible(id, content),

            .pane_visible => |id| try self.receivedPaneVisible(id, content),

            .pane_pending => |id| if (try self.receivedPanePending(id, content)) {
                try actions.append(arena_alloc, .{ .pane_changed = self.panes.get(id).?.change(id) });
                try self.recaptureStaleShownPanes();
                try self.flushPendingResize();
            },

            .pane_pause => |id| try self.receivedPanePaused(id),

            .pane_continue => {},

            .tmux_version => if (try self.receivedTmuxVersion(content)) |reason| {
                return reason;
            },

            .client_size, .resize_client => {},

            .resize_sample_before => if (self.resize_inflight) |*inflight| {
                inflight.before = parseResizeSamples(
                    inflight.arena.allocator(),
                    content,
                ) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => failed: {
                        inflight.failed = true;
                        break :failed &.{};
                    },
                };
            },

            .resize_sample_after => try self.finishResize(arena_alloc, actions, content),
        }
        return null;
    }

    fn receivedTmuxVersion(
        self: *Viewer,
        content: []const u8,
    ) !?ExitReason {
        const line = std.mem.trim(u8, content, " \t\r\n");
        if (line.len == 0) return null;

        const data = output.parseFormatStruct(
            Format.tmux_version.Struct(),
            line,
            Format.tmux_version.delim,
        ) catch |err| {
            log.info("failed to parse tmux version: {s}", .{line});
            return err;
        };

        if (!supportsTmuxVersion(data.version)) {
            log.warn(
                "unsupported tmux version={s}; minimum supported version={s}",
                .{ data.version, minimum_tmux_version },
            );
            return .{ .unsupported_version = data.version };
        }

        if (self.tmux_version.len > 0) {
            self.alloc.free(self.tmux_version);
        }
        self.tmux_version = try self.alloc.dupe(u8, data.version);
        return null;
    }

    fn supportsTmuxVersion(version_raw: []const u8) bool {
        const version = parseTmuxVersion(version_raw) orelse return false;
        const minimum = parseTmuxVersion(minimum_tmux_version).?;
        return version.major > minimum.major or
            (version.major == minimum.major and version.minor >= minimum.minor);
    }

    const TmuxVersion = struct {
        major: usize,
        minor: usize,
    };

    fn parseTmuxVersion(version_raw: []const u8) ?TmuxVersion {
        var version = std.mem.trim(u8, version_raw, " \t\r\n");
        if (std.mem.startsWith(u8, version, "next-")) version = version[5..];

        const dot = std.mem.indexOfScalar(u8, version, '.') orelse return null;
        const major = std.fmt.parseInt(usize, version[0..dot], 10) catch return null;

        var minor_end = dot + 1;
        while (minor_end < version.len and std.ascii.isDigit(version[minor_end])) {
            minor_end += 1;
        }
        if (minor_end == dot + 1) return null;
        const minor = std.fmt.parseInt(
            usize,
            version[dot + 1 .. minor_end],
            10,
        ) catch return null;

        return .{ .major = major, .minor = minor };
    }

    const WindowListData = struct {
        session_id: usize,
        window_id: usize,
        window_active: bool,
        pane_id: usize,
        window_width: usize,
        window_height: usize,
        window_layout: []const u8,
        window_visible_layout: []const u8,
        window_name: []const u8,
    };

    fn parseWindowListPrefix(
        line: []const u8,
    ) error{InvalidWindowRecord}!WindowListData {
        const data = output.parseFormatStruct(
            Format.list_windows_prefix.Struct(),
            line,
            Format.list_windows_prefix.delim,
        ) catch return error.InvalidWindowRecord;
        return .{
            .session_id = data.session_id,
            .window_id = data.window_id,
            .window_active = data.window_active,
            .pane_id = data.pane_id,
            .window_width = data.window_width,
            .window_height = data.window_height,
            .window_layout = data.window_layout,
            .window_visible_layout = data.window_visible_layout,
            .window_name = "",
        };
    }

    fn parseWindowListLine(
        line: []const u8,
    ) error{InvalidWindowRecord}!WindowListData {
        var field_start: usize = 0;
        var prefix_end: ?usize = null;
        for (0..Format.list_windows_prefix.vars.len) |field_index| {
            const relative = std.mem.indexOfScalar(
                u8,
                line[field_start..],
                Format.list_windows.delim,
            ) orelse break;
            const delimiter_index = field_start + relative;
            if (field_index + 1 == Format.list_windows_prefix.vars.len) {
                prefix_end = delimiter_index;
                break;
            }
            field_start = delimiter_index + 1;
        }

        const end = prefix_end orelse return error.InvalidWindowRecord;
        var data = try parseWindowListPrefix(line[0..end]);
        data.window_name = line[end + 1 ..];
        return data;
    }

    fn receivedListWindows(
        self: *Viewer,
        arena_alloc: Allocator,
        actions: *std.ArrayList(Action),
        content: []const u8,
    ) !void {
        // Reserve the action before mutating our model so a failure can't
        // publish new state without its corresponding notification.
        try actions.ensureUnusedCapacity(arena_alloc, 1);

        // This stores our new window state from this list-windows output.
        var windows: std.ArrayList(Window) = .empty;
        var owns_windows = true;
        defer {
            if (owns_windows) {
                for (windows.items) |*window| window.deinit(self.alloc);
            }
            windows.deinit(self.alloc);
        }

        var pending: ?WindowListData = null;
        var pending_name: std.ArrayList(u8) = .empty;
        defer pending_name.deinit(self.alloc);

        // The name is the final field and may contain newlines. A line that
        // is not a complete record therefore continues the preceding name.
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line_raw| {
            const line = std.mem.trimEnd(u8, line_raw, "\r");
            const data = parseWindowListLine(line) catch {
                if (pending == null) {
                    log.info("list-windows response does not begin with a record", .{});
                    return error.InvalidWindowRecord;
                }
                try pending_name.append(self.alloc, '\n');
                try pending_name.appendSlice(self.alloc, line);
                continue;
            };

            if (pending) |previous| {
                try self.appendWindowListRecord(
                    &windows,
                    previous,
                    &pending_name,
                );
            }
            pending = data;
            try pending_name.appendSlice(self.alloc, data.window_name);
        }

        const final = pending orelse return error.InvalidWindowRecord;
        try self.appendWindowListRecord(&windows, final, &pending_name);

        // Sync up our layouts. This will populate unknown panes, prune, etc.
        try self.syncLayouts(windows.items);
        owns_windows = false;

        // A complete list-windows response is the authoritative topology cut.
        // Carries not claimed by one of its panes cannot belong to this
        // session. Partial layout-change notifications must not clear them.
        self.untracked_utf8.clearRetainingCapacity();

        // Publish the Viewer-owned slice. `windows` is temporary and its
        // backing allocation is freed when this function returns.
        actions.appendAssumeCapacity(.{ .windows = self.windows.items });
        try self.afterTopologyChange();
    }

    fn appendWindowListRecord(
        self: *Viewer,
        windows: *std.ArrayList(Window),
        data: WindowListData,
        pending_name: *std.ArrayList(u8),
    ) !void {
        var arena: ArenaAllocator = .init(self.alloc);
        errdefer arena.deinit();
        const window_alloc = arena.allocator();
        const layout: Layout = Layout.parseWithChecksum(
            window_alloc,
            data.window_layout,
        ) catch |err| {
            log.info(
                "failed to parse window layout id={} layout={s}",
                .{ data.window_id, data.window_layout },
            );
            return err;
        };
        const is_zoomed = !std.mem.eql(
            u8,
            data.window_layout,
            data.window_visible_layout,
        );
        const visible_layout: Layout = if (is_zoomed)
            Layout.parseWithChecksum(
                window_alloc,
                data.window_visible_layout,
            ) catch |err| {
                log.info(
                    "failed to parse visible window layout id={} layout={s}",
                    .{ data.window_id, data.window_visible_layout },
                );
                return err;
            }
        else
            layout;

        const name: []const u8 = if (pending_name.items.len == 0)
            ""
        else
            try pending_name.toOwnedSlice(self.alloc);
        errdefer if (name.len > 0) self.alloc.free(name);

        try windows.append(self.alloc, .{
            .id = data.window_id,
            .name = name,
            .width = data.window_width,
            .height = data.window_height,
            .is_zoomed = is_zoomed,
            .is_active = data.window_active,
            .active_pane_id = data.pane_id,
            .layout_arena = arena.state,
            .layout = layout,
            .visible_layout = visible_layout,
        });
    }

    fn receivedPaneState(
        self: *Viewer,
        refresh_id: ?usize,
        content: []const u8,
    ) !bool {
        var metadata_changed = false;
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line_raw| {
            const line = std.mem.trimEnd(u8, line_raw, "\r");
            if (line.len == 0) continue;

            const data = output.parseFormatStructFinalRemainder(
                Format.list_panes.Struct(),
                line,
                Format.list_panes.delim,
            ) catch |err| {
                log.info("failed to parse list-panes line: {s}", .{line});
                return err;
            };
            // Get the pane for this ID
            const entry = self.panes.getEntry(data.pane_id) orelse {
                log.info("received pane state for untracked pane id={}", .{data.pane_id});
                continue;
            };
            const pane: *Pane = entry.value_ptr.*;
            const hydrate_terminal = if (refresh_id) |id| hydrate: {
                if (data.pane_id != id or pane.phase != .refreshing) continue;
                break :hydrate true;
            } else pane.phase == .initial_hydrating;

            metadata_changed = try self.updatePaneMetadata(
                pane,
                data.pane_current_command,
                data.pane_current_path,
            ) or metadata_changed;

            if (!hydrate_terminal) continue;
            if (pane.phase == .refreshing) {
                try pane.snapshot.keep(self.alloc, .state, line);
                continue;
            }

            const terminal_owner = pane.terminal_owner;
            terminal_owner.mutex.lockUncancelable(terminal_owner.terminal.io());
            defer terminal_owner.mutex.unlock(terminal_owner.terminal.io());
            try self.hydratePaneState(pane, &terminal_owner.terminal, data);
        }

        return metadata_changed;
    }

    /// Apply a pane's tmux state to its locked terminal.
    fn hydratePaneState(
        self: *Viewer,
        pane: *Pane,
        t: *Terminal,
        data: Format.list_panes.Struct(),
    ) !void {
        const cols = std.math.cast(
            size.CellCountInt,
            data.pane_width,
        ) orelse return error.InvalidPaneGeometry;
        const rows = std.math.cast(
            size.CellCountInt,
            data.pane_height,
        ) orelse return error.InvalidPaneGeometry;
        if (cols == 0 or rows == 0) return error.InvalidPaneGeometry;
        pane.layout_cols = cols;
        pane.layout_rows = rows;

        if (pane.phase == .refreshing) {
            // Replace only content that the snapshots reconstruct. A DEC
            // RIS/fullReset would also discard live protocol state that
            // tmux does not expose, including charset and Kitty keyboard
            // state. Title, pwd, colors, palette, and terminal modes stay
            // intact until the pane-state fields below overwrite the
            // subset tmux reports.
            const active_key = t.screens.active_key;
            for ([_]ScreenSet.Key{ .primary, .alternate }) |key| {
                const screen = t.screens.get(key) orelse continue;
                t.screens.switchTo(key);
                t.eraseDisplay(.scroll_complete, false);
                screen.eraseHistory(null);
                screen.clearSelection();
            }
            t.screens.switchTo(active_key);
            try t.resize(self.alloc, .{ .cols = cols, .rows = rows });

            // Snapshot replay starts at a fresh protocol boundary. The
            // canonical Terminal and SharedTerminal identities remain
            // unchanged; only the private parser state is replaced.
            pane.stream.deinit();
            pane.stream = Pane.terminalStream(t);
        } else if (t.cols != cols or t.rows != rows) {
            try t.resize(self.alloc, .{ .cols = cols, .rows = rows });
        }

        pane.active_screen = if (data.alternate_on) .alternate else .primary;
        pane.has_history = data.history_size > 0;
        _ = try t.switchScreen(pane.active_screen);

        // Set cursor position on the appropriate screen (tmux uses 0-based)
        const screen = t.screens.active;
        pane.cursor = position: {
            const x = std.math.cast(
                size.CellCountInt,
                data.cursor_x,
            ) orelse break :position null;
            const y = std.math.cast(
                size.CellCountInt,
                data.cursor_y,
            ) orelse break :position null;
            if (y >= screen.pages.rows) break :position null;

            // tmux reports a cursor waiting to wrap one column past the
            // last.
            if (x == screen.pages.cols) {
                break :position .{ .x = x - 1, .y = y, .pending_wrap = true };
            }
            if (x > screen.pages.cols) break :position null;
            break :position .{ .x = x, .y = y };
        };

        // Set cursor shape on the canonical screen.
        if (std.mem.eql(u8, data.cursor_shape, "block")) {
            screen.cursor.cursor_style = .block;
        } else if (std.mem.eql(u8, data.cursor_shape, "underline")) {
            screen.cursor.cursor_style = .underline;
        } else if (std.mem.eql(u8, data.cursor_shape, "bar")) {
            screen.cursor.cursor_style = .bar;
        }

        // Tmux's alternate_saved coordinates are the primary cursor
        // saved while the alternate screen is active.
        const primary = t.screens.get(.primary).?;
        pane.saved_primary_cursor = position: {
            const x = std.math.cast(
                size.CellCountInt,
                data.alternate_saved_x,
            ) orelse break :position null;
            const y = std.math.cast(
                size.CellCountInt,
                data.alternate_saved_y,
            ) orelse break :position null;

            // If our coordinates are outside our screen we ignore it.
            // tmux actually sends MAX_INT for when there isn't a set
            // cursor position, so this isn't theoretical.
            if (x >= primary.pages.cols or y >= primary.pages.rows) {
                break :position null;
            }

            break :position .{ .x = x, .y = y };
        };

        // Set cursor visibility
        t.modes.set(.cursor_visible, data.cursor_flag);

        // Set cursor blinking
        t.modes.set(.cursor_blinking, data.cursor_blinking);

        // Terminal modes
        t.modes.set(.insert, data.insert_flag);
        t.modes.set(.wraparound, data.wrap_flag);
        t.modes.set(.keypad_keys, data.keypad_flag);
        t.modes.set(.cursor_keys, data.keypad_cursor_flag);
        t.modes.set(.origin, data.origin_flag);

        // Mouse modes
        reconcileMouseState(t, data);

        // Focus and bracketed paste
        t.modes.set(.focus_event, data.focus_flag);
        t.modes.set(.bracketed_paste, data.bracketed_paste);

        // Scroll region (tmux uses 0-based values)
        scroll: {
            const scroll_top = std.math.cast(
                size.CellCountInt,
                data.scroll_region_upper,
            ) orelse break :scroll;
            const scroll_bottom = std.math.cast(
                size.CellCountInt,
                data.scroll_region_lower,
            ) orelse break :scroll;

            // Ignore invalid regions. The terminal assumes the scroll
            // region is always within the screen bounds.
            if (scroll_top >= scroll_bottom or
                scroll_bottom >= t.rows) break :scroll;

            t.scrolling_region.top = scroll_top;
            t.scrolling_region.bottom = scroll_bottom;
        }

        // Tab stops - parse comma-separated list and set
        t.tabstops.reset(0); // Clear all tabstops first
        if (data.pane_tabs.len > 0) {
            var tabs_it = std.mem.splitScalar(u8, data.pane_tabs, ',');
            while (tabs_it.next()) |tab_str| {
                const col = std.fmt.parseInt(usize, tab_str, 10) catch continue;
                const col_cell = std.math.cast(size.CellCountInt, col) orelse continue;
                if (col_cell >= t.cols) continue;
                t.tabstops.set(col_cell);
            }
        }
    }

    fn receivedPaneMetadata(
        self: *Viewer,
        content: []const u8,
    ) !bool {
        var changed = false;
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line_raw| {
            const line = std.mem.trimEnd(u8, line_raw, "\r");
            if (line.len == 0) continue;

            const data = output.parseFormatStructFinalRemainder(
                Format.pane_metadata.Struct(),
                line,
                Format.pane_metadata.delim,
            ) catch |err| {
                log.info("failed to parse pane metadata line: {s}", .{line});
                return err;
            };
            const pane = self.panes.get(data.pane_id) orelse continue;
            changed = try self.updatePaneMetadata(
                pane,
                data.pane_current_command,
                data.pane_current_path,
            ) or changed;
        }
        return changed;
    }

    fn updatePaneMetadata(
        self: *Viewer,
        pane: *Pane,
        current_command: []const u8,
        current_path: []const u8,
    ) Allocator.Error!bool {
        var changed = false;
        if (!std.mem.eql(u8, pane.current_command, current_command)) {
            const value = if (current_command.len == 0)
                ""
            else
                try self.alloc.dupe(u8, current_command);
            if (pane.current_command.len > 0) self.alloc.free(pane.current_command);
            pane.current_command = value;
            changed = true;
        }
        if (!std.mem.eql(u8, pane.current_path, current_path)) {
            const value = if (current_path.len == 0)
                ""
            else
                try self.alloc.dupe(u8, current_path);
            if (pane.current_path.len > 0) self.alloc.free(pane.current_path);
            pane.current_path = value;
            changed = true;
        }
        return changed;
    }

    /// Reconcile the subset of mouse state exposed by a tmux pane snapshot.
    /// ModeState retains independently enabled DEC modes while the flags hold
    /// their effective order. Tmux supplies new ordering for reported modes,
    /// but no disable evidence for X10 events or URXVT/SGR-pixels formats, so
    /// those raw bits must remain untouched.
    fn reconcileMouseState(
        terminal: *Terminal,
        data: Format.list_panes.Struct(),
    ) void {
        const event_any = data.mouse_all_flag;
        const event_button = !event_any and data.mouse_button_flag;
        const event_normal = !event_any and
            !event_button and
            data.mouse_standard_flag;
        terminal.modes.set(.mouse_event_any, event_any);
        terminal.modes.set(.mouse_event_button, event_button);
        terminal.modes.set(.mouse_event_normal, event_normal);
        if (event_any) {
            terminal.flags.mouse_event = .any;
        } else if (event_button) {
            terminal.flags.mouse_event = .button;
        } else if (event_normal) {
            terminal.flags.mouse_event = .normal;
        } else if (terminal.flags.mouse_event != .x10) {
            terminal.flags.mouse_event = .none;
        }

        const format_sgr = data.mouse_sgr_flag;
        const format_utf8 = !format_sgr and data.mouse_utf8_flag;
        terminal.modes.set(.mouse_format_sgr, format_sgr);
        terminal.modes.set(.mouse_format_utf8, format_utf8);
        if (format_sgr) {
            terminal.flags.mouse_format = .sgr;
        } else if (format_utf8) {
            terminal.flags.mouse_format = .utf8;
        } else switch (terminal.flags.mouse_format) {
            .urxvt, .sgr_pixels => {},
            else => terminal.flags.mouse_format = .x10,
        }
    }

    fn receivedPaneHistory(
        self: *Viewer,
        id: usize,
        content: []const u8,
    ) !void {
        const pane = self.panes.get(id) orelse {
            log.info("received pane history for untracked pane id={}", .{id});
            return;
        };
        if (pane.phase == .refreshing) return pane.snapshot.keep(self.alloc, .history, content);
        const terminal_owner = pane.terminal_owner;
        terminal_owner.mutex.lockUncancelable(terminal_owner.terminal.io());
        defer terminal_owner.mutex.unlock(terminal_owner.terminal.io());
        try hydratePaneHistory(pane, &terminal_owner.terminal, content);
    }

    fn hydratePaneHistory(pane: *const Pane, t: *Terminal, content: []const u8) !void {
        if (!pane.has_history) return;
        const replay_state = SnapshotReplayState.begin(t);
        defer replay_state.restore(t);
        _ = try t.switchScreen(.primary);
        const screen: *Screen = t.screens.active;

        // Get a VT stream from the terminal so we can send data as-is into
        // it. This will populate the active area too so it won't be exactly
        // correct but we'll get the active contents soon.
        var stream = t.vtStream();
        defer stream.deinit();
        stream.nextSlice(content);

        try t.setAttribute(.unset);

        // Populate the active area to be empty since this is only history.
        // We'll fill it with blanks and move the cursor to the top-left.
        t.carriageReturn();
        for (0..t.rows) |_| try t.index();
        t.setCursorPos(1, 1);

        // Our active area should be empty
        if (comptime std.debug.runtime_safety) {
            var discarding: std.Io.Writer.Discarding = .init(&.{});
            screen.dumpString(&discarding.writer, .{
                .tl = screen.pages.getTopLeft(.active),
                .unwrap = false,
            }) catch unreachable;
            assert(discarding.count == 0);
        }
    }

    fn receivedPaneSavedVisible(
        self: *Viewer,
        id: usize,
        content: []const u8,
    ) !void {
        const pane = self.panes.get(id) orelse {
            log.info("received saved pane content for untracked pane id={}", .{id});
            return;
        };
        if (pane.phase == .refreshing) return pane.snapshot.keep(self.alloc, .saved_visible, content);
        const terminal_owner = pane.terminal_owner;
        terminal_owner.mutex.lockUncancelable(terminal_owner.terminal.io());
        defer terminal_owner.mutex.unlock(terminal_owner.terminal.io());
        try hydratePaneSavedVisible(pane, &terminal_owner.terminal, content);
    }

    fn hydratePaneSavedVisible(pane: *Pane, t: *Terminal, content: []const u8) !void {
        if (pane.active_screen != .alternate) return;
        // tmux prints one line per row; the reply drops the last newline.
        pane.saved_primary_rows = if (content.len == 0) 0 else std.mem.count(u8, content, "\n") + 1;
        try hydrateScreen(t, .primary, content);
    }

    fn receivedPaneVisible(
        self: *Viewer,
        id: usize,
        content: []const u8,
    ) !void {
        const pane = self.panes.get(id) orelse {
            log.info("received pane visible for untracked pane id={}", .{id});
            return;
        };
        if (pane.phase == .refreshing) return pane.snapshot.keep(self.alloc, .visible, content);
        const terminal_owner = pane.terminal_owner;
        terminal_owner.mutex.lockUncancelable(terminal_owner.terminal.io());
        defer terminal_owner.mutex.unlock(terminal_owner.terminal.io());
        try hydrateScreen(&terminal_owner.terminal, pane.active_screen, content);
    }

    fn hydrateScreen(
        t: *Terminal,
        screen_key: ScreenSet.Key,
        content: []const u8,
    ) !void {
        const replay_state = SnapshotReplayState.begin(t);
        defer replay_state.restore(t);
        _ = try t.switchScreen(screen_key);

        try t.setAttribute(.unset);

        // Erase the active area and reset the cursor to the top-left
        // before writing the visible content.
        t.eraseDisplay(.complete, false);
        t.setCursorPos(1, 1);

        var stream = t.vtStream();
        defer stream.deinit();
        stream.nextSlice(content);
    }

    fn receivedPanePending(
        self: *Viewer,
        id: usize,
        content: []const u8,
    ) !bool {
        const pane = self.panes.get(id) orelse {
            log.info("received pending pane content for untracked pane id={}", .{id});
            return false;
        };

        const terminal_owner = pane.terminal_owner;
        terminal_owner.mutex.lockUncancelable(terminal_owner.terminal.io());
        defer terminal_owner.mutex.unlock(terminal_owner.terminal.io());
        const t = &terminal_owner.terminal;
        if (pane.phase == .refreshing) try self.hydrateSnapshot(pane, t);

        Pane.restoreCursor(t.screens.get(.primary).?, pane.saved_primary_cursor);
        _ = try t.switchScreen(pane.active_screen);
        Pane.restoreCursor(t.screens.active, pane.cursor);

        if (content.len > 0) {
            const encoded = try self.alloc.dupe(u8, content);
            defer self.alloc.free(encoded);
            pane.stream.nextSlice(control.decodeEscapedOutput(encoded));
        } else {
            pane.stream.nextSlice(pane.utf8_carry.slice());
        }

        // Output tmux sent after pausing the pane postdates the snapshot.
        if (pane.replay_output) {
            pane.stream.nextSlice(pane.replay.items);
            pane.replay.clearRetainingCapacity();
            pane.replay_output = false;
        }

        pane.utf8_carry.clear();
        pane.region_rows_baseline = t.region_rows_scrolled_out;
        pane.phase = .live;

        // tmux keeps the normal screen at the size it had when the program
        // entered the alternate screen and resizes it when the program
        // leaves. If that size differs from the pane's, the snapshot can't
        // hold it as tmux will, so it's recaptured when the program leaves,
        // or now if it left in the output after the snapshot.
        const snapshot_alternate = pane.active_screen == .alternate;
        const primary_stale = snapshot_alternate and
            (pane.primary_stale or pane.saved_primary_rows != t.rows);
        const left_alternate = snapshot_alternate and t.screens.active_key == .primary;
        pane.primary_stale = primary_stale and !left_alternate;
        if (primary_stale and left_alternate) pane.stale = true;
        return true;
    }

    /// Apply a recapture's kept replies to the pane's locked terminal.
    fn hydrateSnapshot(self: *Viewer, pane: *Pane, t: *Terminal) !void {
        defer pane.snapshot.deinit(self.alloc);
        const parts = &pane.snapshot.parts;
        if (parts.get(.state)) |line| {
            const data = output.parseFormatStructFinalRemainder(
                Format.list_panes.Struct(),
                line,
                Format.list_panes.delim,
            ) catch |err| {
                log.info("failed to parse pane state line: {s}", .{line});
                return err;
            };
            try self.hydratePaneState(pane, t, data);
        }
        if (parts.get(.history)) |content| try hydratePaneHistory(pane, t, content);
        if (parts.get(.saved_visible)) |content| try hydratePaneSavedVisible(pane, t, content);
        if (parts.get(.visible)) |content| try hydrateScreen(t, pane.active_screen, content);
    }

    const OutputResult = struct {
        change: PaneChange,

        /// The pane left the alternate screen after a resize, and its normal
        /// screen must be recaptured.
        recapture: bool = false,
    };

    fn receivedOutput(
        self: *Viewer,
        out: control.Notification.Output,
    ) !?OutputResult {
        if (self.resize_inflight) |*inflight| {
            try inflight.output_panes.put(self.alloc, out.pane_id, {});
        }

        const entry = self.panes.getEntry(out.pane_id) orelse {
            var carry = self.untracked_utf8.get(out.pane_id) orelse Utf8Carry{};
            carry.update(out.data);
            if (carry.len == 0) {
                _ = self.untracked_utf8.swapRemove(out.pane_id);
            } else {
                try self.untracked_utf8.put(self.alloc, out.pane_id, carry);
            }
            return null;
        };
        const pane: *Pane = entry.value_ptr.*;
        const data = control.decodeEscapedOutput(out.data);
        return switch (pane.phase) {
            .initial_hydrating, .refresh_pausing => hydrating: {
                pane.utf8_carry.update(data);
                break :hydrating null;
            },
            .refreshing => refreshing: {
                if (pane.replay_output) {
                    try pane.replay.appendSlice(self.alloc, data);
                } else {
                    pane.utf8_carry.update(data);
                }
                break :refreshing null;
            },
            .live => live: {
                const owner = pane.terminal_owner;
                owner.mutex.lockUncancelable(owner.terminal.io());
                defer owner.mutex.unlock(owner.terminal.io());
                pane.stream.nextSlice(data);
                const left_alternate = pane.primary_stale and
                    owner.terminal.screens.active_key == .primary;
                if (left_alternate) {
                    pane.primary_stale = false;
                    pane.stale = true;
                }
                break :live .{
                    .change = pane.changeLocked(out.pane_id),
                    .recapture = left_alternate,
                };
            },
        };
    }

    const PaneGeometry = struct {
        id: usize,
        width: usize,
        height: usize,
    };

    fn initLayout(
        io: std.Io,
        gpa_alloc: Allocator,
        panes_old: *const PanesMap,
        panes_new: *PanesMap,
        layout: Layout,
        max_scrollback: usize,
        visible_pane: ?PaneGeometry,
        visible_found: *bool,
    ) !void {
        switch (layout.content) {
            // Nested layouts, continue going.
            .horizontal, .vertical => |layouts| {
                for (layouts) |l| {
                    try initLayout(
                        io,
                        gpa_alloc,
                        panes_old,
                        panes_new,
                        l,
                        max_scrollback,
                        visible_pane,
                        visible_found,
                    );
                }
            },

            // A leaf! Initialize.
            .pane => |id| pane: {
                const geometry = if (visible_pane) |visible| geometry: {
                    if (visible.id == id) {
                        visible_found.* = true;
                        break :geometry visible;
                    }
                    break :geometry PaneGeometry{
                        .id = id,
                        .width = layout.width,
                        .height = layout.height,
                    };
                } else PaneGeometry{
                    .id = id,
                    .width = layout.width,
                    .height = layout.height,
                };
                const cols = std.math.cast(
                    size.CellCountInt,
                    geometry.width,
                ) orelse return error.InvalidPaneGeometry;
                const rows = std.math.cast(
                    size.CellCountInt,
                    geometry.height,
                ) orelse return error.InvalidPaneGeometry;
                if (cols == 0 or rows == 0) return error.InvalidPaneGeometry;

                const gop = try panes_new.getOrPut(gpa_alloc, id);
                if (gop.found_existing) break :pane;
                errdefer _ = panes_new.swapRemove(gop.key_ptr.*);

                // If we already have this pane, it is already initialized
                // so just copy it over. A live mirror keeps its size: either
                // a resize this Viewer sent has already applied tmux's rows,
                // or `reconcileGeometry` handles a resize from elsewhere. A
                // snapshot in progress replaces the contents anyway.
                if (panes_old.getEntry(id)) |entry| {
                    const pane = entry.value_ptr.*;
                    pane.layout_cols = cols;
                    pane.layout_rows = rows;
                    if (pane.phase != .live) {
                        const terminal_owner = pane.terminal_owner;
                        terminal_owner.mutex.lockUncancelable(terminal_owner.terminal.io());
                        defer terminal_owner.mutex.unlock(terminal_owner.terminal.io());
                        try terminal_owner.terminal.resize(gpa_alloc, .{ .cols = cols, .rows = rows });
                        if (pane.active_screen == .alternate) pane.primary_stale = true;
                    }
                    gop.value_ptr.* = pane;
                    break :pane;
                }

                const pane = try Pane.init(io, gpa_alloc, .{
                    .cols = cols,
                    .rows = rows,
                    .max_scrollback_bytes = max_scrollback,
                });
                pane.layout_cols = cols;
                pane.layout_rows = rows;
                gop.value_ptr.* = pane;
            },
        }
    }

    /// Build the canonical snapshot sequence used by both first hydration and
    /// in-place refresh. The pane-state command is shared across new panes and
    /// is prepended separately by each caller.
    fn paneHydrationCommands(
        self: *const Viewer,
        pane_id: usize,
        storage: []Command,
    ) []const Command {
        assert(storage.len >= 4);
        var len: usize = 0;
        if (self.options.history_line_limit == null or
            self.options.history_line_limit.? > 0)
        {
            storage[len] = .{ .pane_history = .{
                .id = pane_id,
                .line_limit = self.options.history_line_limit,
            } };
            len += 1;
        }
        storage[len] = .{ .pane_saved_visible = pane_id };
        len += 1;
        storage[len] = .{ .pane_visible = pane_id };
        len += 1;
        storage[len] = .{ .pane_pending = pane_id };
        len += 1;
        return storage[0..len];
    }

    /// Enters the command queue state from any other state, queueing and
    /// emitting every complete command group.
    fn enterCommandQueue(
        self: *Viewer,
        arena_alloc: Allocator,
        commands: []const Command,
    ) (Allocator.Error || std.Io.Writer.Error)![]const Action {
        assert(self.state != .command_queue);
        assert(commands.len > 0);

        try self.queueCommands(commands);

        // Move into the command queue state
        self.state = .command_queue;

        var actions: std.ArrayList(Action) = .empty;
        try self.appendQueuedCommandActionsWithAllocator(&actions, arena_alloc);
        return actions.items;
    }

    /// Queue multiple independent commands. A caller must finish its current
    /// input by calling `appendQueuedCommandActions` so newly complete groups
    /// are emitted immediately.
    fn queueCommands(
        self: *Viewer,
        commands: []const Command,
    ) Allocator.Error!void {
        try self.command_queue.ensureUnusedCapacity(
            self.alloc,
            commands.len,
        );
        for (commands) |command| {
            self.command_queue.appendAssumeCapacity(.{
                .command = command,
                .group_end = true,
            });
        }
    }

    /// Format and emit every complete group that has not already been sent.
    fn appendQueuedCommandActions(
        self: *Viewer,
        actions: *std.ArrayList(Action),
    ) (Allocator.Error || std.Io.Writer.Error)!void {
        var arena = self.action_arena.promote(self.alloc);
        defer self.action_arena = arena.state;
        try self.appendQueuedCommandActionsWithAllocator(actions, arena.allocator());
    }

    fn appendQueuedCommandActionsWithAllocator(
        self: *Viewer,
        actions: *std.ArrayList(Action),
        arena_alloc: Allocator,
    ) (Allocator.Error || std.Io.Writer.Error)!void {
        assert(self.sent_command_count <= self.command_queue.len());
        var it = self.command_queue.iterator(.forward);
        it.seekBy(@intCast(self.sent_command_count));

        while (it.idx < self.command_queue.len()) {
            var members: std.ArrayList([]const u8) = .empty;
            var command_count: usize = 0;
            var ended_group = false;
            while (it.next()) |queued| {
                var builder: std.Io.Writer.Allocating = .init(arena_alloc);
                try queued.command.formatCommand(&builder.writer);
                const member = builder.writer.buffered();
                assert(member.len > 0);
                assert(std.mem.indexOfAny(u8, member, "\r\n") == null);
                try members.append(arena_alloc, member);
                command_count += 1;
                if (queued.group_end) {
                    ended_group = true;
                    break;
                }
            }

            assert(members.items.len > 0);
            assert(ended_group);

            // The sent watermark advances only after both the borrowed group
            // and its action have been built successfully.
            try actions.append(arena_alloc, .{ .command = .{
                .members = members.items,
            } });
            self.sent_command_count += command_count;
        }
    }

    /// Helper to return a single action. The input action may use the arena
    /// for allocated memory; this will not touch the arena.
    fn singleAction(self: *Viewer, action: Action) []const Action {
        // Make our single action slice.
        self.action_single[0] = action;
        return &self.action_single;
    }

    fn defunct(self: *Viewer) []const Action {
        return self.defunctWith(.client_failure);
    }

    fn defunctWith(
        self: *Viewer,
        reason: ExitReason,
    ) []const Action {
        self.state = .defunct;
        return self.singleAction(.{ .exit = reason });
    }
};

const State = enum {
    /// We start in this state just after receiving the initial
    /// DCS 1000p opening sequence. We wait for an initial
    /// begin/end block that is guaranteed to be sent by tmux for
    /// the initial control mode command. (See tmux server-client.c
    /// where control mode starts).
    startup_block,

    /// After receiving the initial block, we wait for a session-changed
    /// notification to record the initial session ID.
    startup_session,

    /// Tmux has closed the control mode connection
    defunct,

    /// We're sitting on the command queue waiting for command output
    /// in the order provided in the `command_queue` field. This field
    /// isn't part of the state because it can be queued at any state.
    ///
    /// Precondition: if self.command_queue.len > 0, then the first
    /// command in the queue has already been sent to tmux (via a
    /// `command` Action). The next output is assumed to be the result
    /// of this command.
    ///
    /// To satisfy the above, any transitions INTO this state should
    /// send a command Action for the first command in the queue.
    command_queue,
};

const QueuedCommand = struct {
    command: Command,
    group_end: bool,
    refresh_pane_id: ?usize = null,
};

const Command = union(enum) {
    /// List all windows so we can sync our window state.
    list_windows,

    /// Capture history for the given pane ID.
    pane_history: CaptureHistory,

    /// Capture the primary screen saved behind an active alternate screen.
    pane_saved_visible: usize,

    /// Capture the current visible area for the given pane ID.
    pane_visible: usize,

    /// Capture output queued while the pane snapshots were taken.
    pane_pending: usize,

    /// Capture the pane terminal state as best we can. The pane ID(s)
    /// are part of the output so we can map it back to our panes.
    pane_state,

    /// Capture authoritative state for one in-place pane refresh. A targeted
    /// display-message returns only this pane, keeping the response small and
    /// binding its geometry to this group without enumerating siblings.
    pane_refresh_state: usize,

    /// Refresh pane labels for one window without touching terminal state.
    pane_metadata: usize,

    /// Get the tmux server version.
    tmux_version,

    /// Report the initial control-client grid before querying topology.
    client_size: Viewer.ClientSize,

    /// A client resize Remux applies itself: every pane sampled before and
    /// after `refresh-client -C` in one command line, which tmux runs without
    /// parsing pane output in between.
    resize_sample_before,
    resize_client: Viewer.ClientSize,
    resize_sample_after,

    /// Stop and resume tmux's output for one pane around a recapture, so
    /// output the snapshot already contains is never applied again.
    pane_pause: usize,
    pane_continue: usize,

    /// User command. This is a command provided by the user. Since
    /// this is user provided, we can't be sure what it is.
    user: []const u8,

    const CaptureHistory = struct {
        id: usize,
        line_limit: ?usize,
    };

    pub fn deinit(self: Command, alloc: Allocator) void {
        return switch (self) {
            .list_windows,
            .pane_history,
            .pane_saved_visible,
            .pane_visible,
            .pane_pending,
            .pane_state,
            .pane_refresh_state,
            .pane_metadata,
            .tmux_version,
            .client_size,
            .resize_sample_before,
            .resize_client,
            .resize_sample_after,
            .pane_pause,
            .pane_continue,
            => {},
            .user => |v| alloc.free(v),
        };
    }

    fn isHydration(self: Command) bool {
        return switch (self) {
            .pane_state,
            .pane_refresh_state,
            .pane_history,
            .pane_saved_visible,
            .pane_visible,
            .pane_pending,
            .pane_pause,
            .pane_continue,
            => true,
            .list_windows,
            .pane_metadata,
            .tmux_version,
            .client_size,
            .resize_sample_before,
            .resize_client,
            .resize_sample_after,
            .user,
            => false,
        };
    }

    /// Format one command member without transport framing.
    pub fn formatCommand(
        self: Command,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            .list_windows => try writer.writeAll(std.fmt.comptimePrint(
                "list-windows -F '{s}'",
                .{comptime Format.list_windows.comptimeFormat()},
            )),

            .pane_history => |capture| {
                // -S - starts at the oldest retained row. A negative number
                // requests at most that many rows before the visible area.
                if (capture.line_limit) |limit| {
                    assert(limit > 0);
                    try writer.print(
                        "capture-pane -p -e -N -q -S -{d} -E -1 -t %{d}",
                        .{ limit, capture.id },
                    );
                } else {
                    try writer.print(
                        "capture-pane -p -e -N -q -S - -E -1 -t %{d}",
                        .{capture.id},
                    );
                }
            },

            .pane_saved_visible => |id| try writer.print(
                // -p = output to stdout instead of buffer
                // -e = output escape sequences for SGR
                // -N = preserve trailing cells and their styles
                // -a = capture the saved primary screen behind alternate
                // -q = return empty if no saved screen exists
                "capture-pane -p -e -N -a -q -t %{d}",
                .{id},
            ),

            .pane_visible => |id| try writer.print(
                // -N preserves styled trailing cells in the current grid.
                "capture-pane -p -e -N -q -t %{d}",
                .{id},
            ),

            .pane_pending => |id| try writer.print(
                // -P = pending output not yet written to the pane
                // -C = octal-escape non-printable bytes
                "capture-pane -p -P -C -t %{d}",
                .{id},
            ),

            .pane_state => try writer.writeAll(std.fmt.comptimePrint(
                "list-panes -s -F '{s}'",
                .{comptime Format.list_panes.comptimeFormat()},
            )),

            .pane_refresh_state => |id| try writer.print(
                "display-message -p -t %{d} -F '{s}'",
                .{ id, comptime Format.list_panes.comptimeFormat() },
            ),

            .pane_metadata => |window_id| try writer.print(
                "list-panes -t @{d} -F '{s}'",
                .{ window_id, comptime Format.pane_metadata.comptimeFormat() },
            ),

            .tmux_version => try writer.writeAll(std.fmt.comptimePrint(
                "display-message -p '{s}'",
                .{comptime Format.tmux_version.comptimeFormat()},
            )),

            .client_size, .resize_client => |client_size| try writer.print(
                "refresh-client -C {d}x{d}",
                .{ client_size.columns, client_size.rows },
            ),

            .resize_sample_before, .resize_sample_after => try writer.writeAll(std.fmt.comptimePrint(
                "list-panes -s -F '{s}'",
                .{Format.resize_sample_format},
            )),

            .pane_pause => |id| try writer.print("refresh-client -A '%{d}:pause'", .{id}),

            .pane_continue => |id| try writer.print("refresh-client -A '%{d}:continue'", .{id}),

            .user => |v| try writer.writeAll(v),
        }
    }
};

/// Format strings used for commands in our viewer.
const Format = struct {
    /// The variables included in this format, in order.
    vars: []const output.Variable,

    /// The delimiter to use between variables. Formats whose final field may
    /// contain it must use the final-remainder parser.
    delim: u8,

    const list_panes: Format = .{
        .delim = ';',
        .vars = &.{
            .pane_id,
            .pane_width,
            .pane_height,
            // Cursor position & appearance
            .cursor_x,
            .cursor_y,
            .cursor_flag,
            .cursor_shape,
            .cursor_colour,
            .cursor_blinking,
            // Alternate screen
            .alternate_on,
            .alternate_saved_x,
            .alternate_saved_y,
            // Terminal modes
            .insert_flag,
            .wrap_flag,
            .keypad_flag,
            .keypad_cursor_flag,
            .origin_flag,
            // Mouse modes
            .mouse_all_flag,
            .mouse_button_flag,
            .mouse_standard_flag,
            .mouse_utf8_flag,
            .mouse_sgr_flag,
            // Focus & special features
            .focus_flag,
            .bracketed_paste,
            .history_size,
            // Scroll region
            .scroll_region_upper,
            .scroll_region_lower,
            // Tab stops
            .pane_tabs,
            .pane_current_command,
            .pane_current_path,
        },
    };

    const pane_metadata: Format = .{
        .delim = ';',
        .vars = &.{
            .pane_id,
            .pane_current_command,
            .pane_current_path,
        },
    };

    const resize_sample: Format = .{
        .delim = ';',
        .vars = &.{
            .pane_id,
            .pane_width,
            .pane_height,
            .cursor_x,
            .cursor_y,
            .history_size,
            .alternate_on,
            .window_layout,
            .window_visible_layout,
        },
    };

    /// The `resize_sample` fields, sent on every resize for every pane in
    /// the session. A window's layout is needed once, and its visible
    /// layout only while it's zoomed, so tmux prints them only for the
    /// window's top-left pane and its zoomed (active) pane and leaves both
    /// fields empty elsewhere.
    const resize_sample_format = format: {
        const pane_fields: Format = .{
            .delim = ';',
            .vars = resize_sample.vars[0 .. resize_sample.vars.len - 2],
        };
        break :format pane_fields.comptimeFormat() ++
            ";#{?#{||:#{&&:#{window_zoomed_flag},#{pane_active}},#{&&:#{pane_at_top},#{pane_at_left}}}," ++
            "#{window_layout};#{?window_zoomed_flag,#{window_visible_layout},},;}";
    };

    const list_windows: Format = .{
        .delim = ' ',
        .vars = &.{
            .session_id,
            .window_id,
            .window_active,
            .pane_id,
            .window_width,
            .window_height,
            .window_layout,
            .window_visible_layout,
            .window_name,
        },
    };

    const list_windows_prefix: Format = .{
        .delim = ' ',
        .vars = Format.list_windows.vars[0 .. Format.list_windows.vars.len - 1],
    };

    const tmux_version: Format = .{
        .delim = ' ',
        .vars = &.{.version},
    };

    /// The format string, available at comptime.
    pub fn comptimeFormat(comptime self: Format) []const u8 {
        return output.comptimeFormat(self.vars, self.delim);
    }

    /// The struct that can contain the parsed output.
    pub fn Struct(comptime self: Format) type {
        return output.FormatStruct(self.vars);
    }
};

fn testClientBlock(data: []const u8) control.Notification.Block {
    return .{
        .data = data,
        .meta = .{ .time = 0, .number = 0, .flags = 1 },
    };
}

const TestPaneState = struct {
    pane_id: usize = 1,
    pane_current_command: []const u8 = "zsh",
    pane_current_path: []const u8 = "/Users/test/project",
    cursor_y: usize = 0,
    alternate_on: bool = false,
    mouse_all: bool = false,
    mouse_button: bool = false,
    mouse_standard: bool = false,
    mouse_utf8: bool = false,
    mouse_sgr: bool = false,
    scroll_region_upper: usize = 0,
    scroll_region_lower: usize = 2,
};

fn testPaneState(
    buffer: []u8,
    state: TestPaneState,
) std.fmt.BufPrintError![]const u8 {
    return std.fmt.bufPrint(
        buffer,
        "%{d};10;3;0;{d};1;block;;0;{d};4294967295;4294967295;" ++
            "0;1;0;0;0;{d};{d};{d};{d};{d};0;0;0;{d};{d};;{s};{s}",
        .{
            state.pane_id,
            state.cursor_y,
            @intFromBool(state.alternate_on),
            @intFromBool(state.mouse_all),
            @intFromBool(state.mouse_button),
            @intFromBool(state.mouse_standard),
            @intFromBool(state.mouse_utf8),
            @intFromBool(state.mouse_sgr),
            state.scroll_region_upper,
            state.scroll_region_lower,
            state.pane_current_command,
            state.pane_current_path,
        },
    );
}

fn addTestPane(viewer: *Viewer) Allocator.Error!*Viewer.Pane {
    const pane = try Viewer.Pane.init(testing.io, testing.allocator, .{
        .cols = 10,
        .rows = 3,
    });
    errdefer pane.deinit(testing.allocator);
    try viewer.panes.put(testing.allocator, 1, pane);
    return pane;
}

const TestStep = struct {
    input: Viewer.Input,
    contains_tags: []const std.meta.Tag(Viewer.Action) = &.{},
    contains_command: []const u8 = "",
    check: ?*const fn (viewer: *Viewer, []const Viewer.Action) anyerror!void = null,
    check_command: ?*const fn (viewer: *Viewer, []const u8) anyerror!void = null,

    fn run(self: TestStep, viewer: *Viewer) !void {
        const actions = viewer.next(self.input);

        // Member text is unframed; the group writer owns separators and the
        // single transport newline.
        for (actions) |action| {
            if (action == .command) {
                for (action.command.members) |member| {
                    try testing.expect(member.len > 0);
                    try testing.expect(std.mem.indexOfAny(u8, member, "\r\n") == null);
                }
                var serialized: std.Io.Writer.Allocating = .init(testing.allocator);
                defer serialized.deinit();
                try action.command.write(&serialized.writer);
                try testing.expect(std.mem.endsWith(
                    u8,
                    serialized.writer.buffered(),
                    "\n",
                ));
            }
        }

        for (self.contains_tags) |tag| {
            var found = false;
            for (actions) |action| {
                if (action == tag) {
                    found = true;
                    break;
                }
            }
            try testing.expect(found);
        }

        if (self.contains_command.len > 0) {
            var found = false;
            for (actions) |action| {
                if (action == .command and
                    std.mem.startsWith(
                        u8,
                        action.command.members[0],
                        self.contains_command,
                    ))
                {
                    found = true;
                    break;
                }
            }
            try testing.expect(found);
        }

        if (self.check) |check_fn| {
            try check_fn(viewer, actions);
        }

        if (self.check_command) |check_fn| {
            var found = false;
            for (actions) |action| {
                if (action == .command) {
                    found = true;
                    var serialized: std.Io.Writer.Allocating = .init(testing.allocator);
                    defer serialized.deinit();
                    try action.command.write(&serialized.writer);
                    try check_fn(viewer, serialized.writer.buffered());
                }
            }
            try testing.expect(found);
        }
    }
};

/// A helper to run a series of test steps against a viewer and assert
/// that the expected actions are produced.
///
/// I'm generally not a fan of these types of abstracted tests because
/// it makes diagnosing failures harder, but being able to construct
/// simulated tmux inputs and verify outputs is going to be extremely
/// important since the tmux control mode protocol is very complex and
/// fragile.
fn testViewer(viewer: *Viewer, steps: []const TestStep) !void {
    for (steps, 0..) |step, i| {
        step.run(viewer) catch |err| {
            log.warn("testViewer step failed i={} step={}", .{ i, step });
            return err;
        };
    }
}

test "retained terminal outlives concurrent pane removal" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    const pane = try Viewer.Pane.init(testing.io, testing.allocator, .{
        .cols = 10,
        .rows = 2,
    });
    viewer.panes.put(testing.allocator, 1, pane) catch |err| {
        pane.deinit(testing.allocator);
        return err;
    };

    const Context = struct {
        terminal: *SharedTerminal,
        locked: std.Io.Event = .unset,
        proceed: std.Io.Event = .unset,
        done: std.Io.Event = .unset,
        observed_cols: size.CellCountInt = 0,

        fn run(self: *@This()) void {
            self.terminal.mutex.lockUncancelable(self.terminal.terminal.io());
            self.locked.set(testing.io);
            self.proceed.waitUncancelable(testing.io);
            self.observed_cols = self.terminal.terminal.cols;
            self.terminal.mutex.unlock(self.terminal.terminal.io());
            self.terminal.release();
            self.done.set(testing.io);
        }
    };
    var context: Context = .{ .terminal = pane.retainTerminal() };
    const thread = std.Thread.spawn(.{}, Context.run, .{&context}) catch |err| {
        context.terminal.release();
        return err;
    };
    defer {
        context.proceed.set(testing.io);
        thread.join();
    }

    try context.locked.waitTimeout(testing.io, .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } });
    try viewer.syncLayouts(&.{});
    try testing.expectEqual(0, viewer.panes.count());
    context.proceed.set(testing.io);
    try context.done.waitTimeout(testing.io, .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } });
    try testing.expectEqual(10, context.observed_cols);
}

test "minimum tmux version" {
    try testing.expect(!Viewer.supportsTmuxVersion("2.9a"));
    try testing.expect(!Viewer.supportsTmuxVersion("3.0a"));
    try testing.expect(Viewer.supportsTmuxVersion("3.1"));
    try testing.expect(Viewer.supportsTmuxVersion("3.1c"));
    try testing.expect(Viewer.supportsTmuxVersion("3.2a"));
    try testing.expect(Viewer.supportsTmuxVersion("next-3.1"));
    try testing.expect(Viewer.supportsTmuxVersion("4.0"));
    try testing.expect(!Viewer.supportsTmuxVersion("3"));
    try testing.expect(!Viewer.supportsTmuxVersion("3.x"));
    try testing.expect(!Viewer.supportsTmuxVersion("unknown"));
}

test "list-windows parses the complete final window name" {
    const prefix =
        "$42 @7 1 %3 83 44 b7dd,83x44,0,0,3 b7dd,83x44,0,0,3";

    const named = try Viewer.parseWindowListLine(prefix ++ " editor window");
    try testing.expectEqual(42, named.session_id);
    try testing.expectEqual(7, named.window_id);
    try testing.expectEqualStrings("editor window", named.window_name);

    const padded = try Viewer.parseWindowListLine(prefix ++ "  padded name  ");
    try testing.expectEqualStrings(" padded name  ", padded.window_name);

    const empty = try Viewer.parseWindowListLine(prefix ++ " ");
    try testing.expectEqualStrings("", empty.window_name);

    const escaped_control = try Viewer.parseWindowListLine(prefix ++ " a\\001b");
    try testing.expectEqualStrings("a\\001b", escaped_control.window_name);

    const escaped_sequence = try Viewer.parseWindowListLine(prefix ++ " e\\033]x");
    try testing.expectEqualStrings("e\\033]x", escaped_sequence.window_name);

    const escaped_invalid = try Viewer.parseWindowListLine(prefix ++ " f\\377g");
    try testing.expectEqualStrings("f\\377g", escaped_invalid.window_name);

    const raw_tab = try Viewer.parseWindowListLine(prefix ++ " tab\tname");
    try testing.expectEqualStrings("tab\tname", raw_tab.window_name);

    try testing.expectError(
        error.InvalidWindowRecord,
        Viewer.parseWindowListLine(prefix),
    );
}

test "list-windows command requests the standard tmux window name" {
    var builder: std.Io.Writer.Allocating = .init(testing.allocator);
    defer builder.deinit();
    const command: Command = .list_windows;
    try command.formatCommand(&builder.writer);
    try testing.expect(std.mem.endsWith(
        u8,
        builder.writer.buffered(),
        " #{window_name}'",
    ));
}

test "pane state query requests specific tmux mouse flags" {
    // The aggregate mouse_any_flag is not an output variable, so the query
    // can only request the specific selector and format flags.
    for ([_]output.Variable{
        .mouse_all_flag,
        .mouse_button_flag,
        .mouse_standard_flag,
        .mouse_utf8_flag,
        .mouse_sgr_flag,
    }) |variable| {
        try testing.expect(std.mem.indexOfScalar(output.Variable, Format.list_panes.vars, variable) != null);
    }
}

test "pane hydration restores tmux mouse modes and effective flags" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();
    const pane = try addTestPane(&viewer);
    const terminal = &pane.terminal_owner.terminal;
    var state_buffer: [256]u8 = undefined;

    const cases = [_]struct {
        state: TestPaneState,
        event: mouse.Event,
        format: mouse.Format,
        screen: ScreenSet.Key = .primary,
    }{
        .{
            .state = .{ .mouse_standard = true, .mouse_utf8 = true },
            .event = .normal,
            .format = .utf8,
        },
        .{
            // The alternate-screen case proves routing observes the hydrated
            // effective mode before the application emits any live output.
            .state = .{
                .alternate_on = true,
                .mouse_button = true,
                .mouse_sgr = true,
            },
            .event = .button,
            .format = .sgr,
            .screen = .alternate,
        },
        .{
            // Conflicting input also proves all-motion and SGR precedence.
            .state = .{
                .mouse_all = true,
                .mouse_button = true,
                .mouse_standard = true,
                .mouse_utf8 = true,
                .mouse_sgr = true,
            },
            .event = .any,
            .format = .sgr,
        },
        .{ .state = .{}, .event = .none, .format = .x10 },
    };

    for (cases) |case| {
        _ = try viewer.receivedPaneState(null, try testPaneState(&state_buffer, case.state));
        try testing.expectEqual(case.screen, pane.active_screen);
        try testing.expectEqual(terminal.screens.get(case.screen).?, terminal.screens.active);
        try testing.expectEqual(case.event, terminal.flags.mouse_event);
        try testing.expectEqual(case.event == .normal, terminal.modes.get(.mouse_event_normal));
        try testing.expectEqual(case.event == .button, terminal.modes.get(.mouse_event_button));
        try testing.expectEqual(case.event == .any, terminal.modes.get(.mouse_event_any));
        try testing.expect(!terminal.modes.get(.mouse_event_x10));
        try testing.expectEqual(case.format, terminal.flags.mouse_format);
        try testing.expectEqual(case.format == .utf8, terminal.modes.get(.mouse_format_utf8));
        try testing.expectEqual(case.format == .sgr, terminal.modes.get(.mouse_format_sgr));
        try testing.expect(!terminal.modes.get(.mouse_format_urxvt));
        try testing.expect(!terminal.modes.get(.mouse_format_sgr_pixels));
    }
}

test "pane state ignores out of bounds scroll regions" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();
    viewer.state = .command_queue;
    const pane = try addTestPane(&viewer);
    const terminal = &pane.terminal_owner.terminal;
    var state_buffer: [256]u8 = undefined;

    // An empty region, then one far past the screen. The rest of the line
    // still applies.
    for ([_][2]usize{ .{ 2, 1 }, .{ 0, 60000 } }) |region| {
        _ = try viewer.receivedPaneState(null, try testPaneState(&state_buffer, .{
            .cursor_y = 2,
            .scroll_region_upper = region[0],
            .scroll_region_lower = region[1],
        }));
        try testing.expectEqual(2, pane.cursor.?.y);
        try testing.expectEqual(0, terminal.scrolling_region.top);
        try testing.expectEqual(terminal.rows - 1, terminal.scrolling_region.bottom);
    }

    // Vertical tabs act as linefeeds and must scroll within the screen.
    pane.phase = .live;
    var vertical_tabs = [_]u8{0x0b} ** 30;
    _ = viewer.next(.{ .tmux = .{ .output = .{
        .pane_id = 1,
        .data = &vertical_tabs,
    } } });
    try testing.expectEqual(terminal.rows - 1, terminal.screens.active.cursor.y);
}

test "pane refresh preserves parser-only mouse modes" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();
    const pane = try addTestPane(&viewer);
    const terminal = &pane.terminal_owner.terminal;
    var state_buffer: [256]u8 = undefined;

    _ = try viewer.receivedPaneState(null, try testPaneState(&state_buffer, .{}));
    pane.stream.nextSlice("\x1b[?9h\x1b[?1015h");
    pane.phase = .refreshing;
    _ = try viewer.receivedPaneState(1, try testPaneState(&state_buffer, .{}));
    _ = try viewer.receivedPanePending(1, "");
    try testing.expectEqual(.x10, terminal.flags.mouse_event);
    try testing.expect(terminal.modes.get(.mouse_event_x10));
    try testing.expectEqual(.urxvt, terminal.flags.mouse_format);
    try testing.expect(terminal.modes.get(.mouse_format_urxvt));

    pane.stream.nextSlice("\x1b[?1016h");
    pane.phase = .refreshing;
    _ = try viewer.receivedPaneState(1, try testPaneState(&state_buffer, .{}));
    _ = try viewer.receivedPanePending(1, "");
    try testing.expectEqual(.x10, terminal.flags.mouse_event);
    try testing.expect(terminal.modes.get(.mouse_event_x10));
    try testing.expectEqual(.sgr_pixels, terminal.flags.mouse_format);
    try testing.expect(terminal.modes.get(.mouse_format_urxvt));
    try testing.expect(terminal.modes.get(.mouse_format_sgr_pixels));
}

test "active topology creates configured pane terminals" {
    const max_scrollback: usize = 123_456;
    var viewer = try Viewer.init(testing.io, testing.allocator, .{
        .max_scrollback = max_scrollback,
    });
    defer viewer.deinit();
    viewer.state = .command_queue;
    viewer.session_id = 42;

    const topology =
        \\$42 @0 1 %0 83 44 b7dd,83x44,0,0,0 b7dd,83x44,0,0,0 zero
        \\$42 @1 0 %1 83 44 b7de,83x44,0,0,1 b7de,83x44,0,0,1 one
    ;
    {
        var arena = viewer.action_arena.promote(viewer.alloc);
        defer viewer.action_arena = arena.state;
        var actions: std.ArrayList(Viewer.Action) = .empty;
        try viewer.receivedListWindows(
            arena.allocator(),
            &actions,
            topology,
        );
        try testing.expectEqual(1, actions.items.len);
        try testing.expect(actions.items[0] == .windows);
    }

    try testing.expectEqual(2, viewer.windows.items.len);
    try testing.expect(viewer.windows.items[0].is_active);
    try testing.expectEqual(0, viewer.windows.items[0].active_pane_id);
    try testing.expect(!viewer.windows.items[1].is_active);
    try testing.expectEqual(1, viewer.windows.items[1].active_pane_id);
    {
        const terminal_owner = viewer.panes.get(0).?.terminal_owner;
        terminal_owner.mutex.lockUncancelable(terminal_owner.terminal.io());
        defer terminal_owner.mutex.unlock(terminal_owner.terminal.io());
        try testing.expectEqual(
            max_scrollback,
            terminal_owner.terminal.screens.get(.primary).?.pages.limits.bytes.explicit,
        );
    }

    const queue_len = viewer.command_queue.len();
    const sent_command_count = viewer.sent_command_count;
    const pane_count = viewer.panes.count();
    {
        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        failing.fail_index = failing.alloc_index;
        const original_alloc = viewer.alloc;
        defer viewer.alloc = original_alloc;
        viewer.alloc = failing.allocator();

        const pane_changed = viewer.next(.{ .tmux = .{
            .window_pane_changed = .{ .window_id = 1, .pane_id = 7 },
        } });
        try testing.expectEqual(1, pane_changed.len);
        try testing.expect(pane_changed[0] == .windows);
        try testing.expectEqual(viewer.windows.items.ptr, pane_changed[0].windows.ptr);
        try testing.expectEqual(7, viewer.windows.items[1].active_pane_id);

        try testing.expectEqual(0, viewer.next(.{ .tmux = .{
            .window_pane_changed = .{ .window_id = 1, .pane_id = 7 },
        } }).len);
        try testing.expectEqual(0, viewer.next(.{ .tmux = .{
            .window_pane_changed = .{ .window_id = 99, .pane_id = 9 },
        } }).len);
        try testing.expectEqual(0, viewer.next(.{ .tmux = .{
            .session_window_changed = .{ .session_id = 99, .window_id = 1 },
        } }).len);
        try testing.expectEqual(0, viewer.next(.{ .tmux = .{
            .session_window_changed = .{ .session_id = 42, .window_id = 99 },
        } }).len);

        const window_changed = viewer.next(.{ .tmux = .{
            .session_window_changed = .{ .session_id = 42, .window_id = 1 },
        } });
        try testing.expectEqual(1, window_changed.len);
        try testing.expect(window_changed[0] == .windows);
        try testing.expect(!viewer.windows.items[0].is_active);
        try testing.expect(viewer.windows.items[1].is_active);
        try testing.expectEqual(0, viewer.next(.{ .tmux = .{
            .session_window_changed = .{ .session_id = 42, .window_id = 1 },
        } }).len);
    }

    try testing.expectEqual(queue_len, viewer.command_queue.len());
    try testing.expectEqual(sent_command_count, viewer.sent_command_count);
    try testing.expectEqual(pane_count, viewer.panes.count());

    viewer.resetActionArena();
    var layout_actions: std.ArrayList(Viewer.Action) = .empty;
    try viewer.layoutChanged(
        &layout_actions,
        1,
        "b7de,83x44,0,0,1",
        "b7de,83x44,0,0,1",
    );
    try testing.expectEqual(1, layout_actions.items.len);
    try testing.expect(viewer.windows.items[1].is_active);
    try testing.expectEqual(7, viewer.windows.items[1].active_pane_id);

    viewer.resetActionArena();
    {
        var arena = viewer.action_arena.promote(viewer.alloc);
        defer viewer.action_arena = arena.state;
        var actions: std.ArrayList(Viewer.Action) = .empty;
        try viewer.receivedListWindows(
            arena.allocator(),
            &actions,
            topology,
        );
        try testing.expectEqual(1, actions.items.len);
    }
    try testing.expect(viewer.windows.items[0].is_active);
    try testing.expectEqual(0, viewer.windows.items[0].active_pane_id);
    try testing.expect(!viewer.windows.items[1].is_active);
    try testing.expectEqual(1, viewer.windows.items[1].active_pane_id);
}

test "unsupported tmux exits before topology hydration" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .handshake_ok },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "old",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = testClientBlock("3.0a") } },
            .contains_tags = &.{.exit},
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, actions.len);
                    try testing.expectEqual(State.defunct, v.state);
                    try testing.expectEqualStrings("", v.tmux_version);
                }
            }).check,
        },
    });
}

test "zero history limit omits initial history capture" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{
        .history_line_limit = 0,
    });
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{ .input = .handshake_ok },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "no-history",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = testClientBlock("3.1") } },
        },
        .{
            .input = .{ .tmux = .{
                .block_end = testClientBlock("$1 @0 1 %0 83 44 b7dd,83x44,0,0,0 b7dd,83x44,0,0,0 shell"),
            } },
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.startsWith(u8, command, "list-panes -s"));
                    try testing.expectEqual(3, std.mem.count(u8, command, "capture-pane"));
                    try testing.expectEqual(3, std.mem.count(u8, command, " ; "));
                    try testing.expectEqual(3, std.mem.count(u8, command, "-t %0"));
                    try testing.expect(!std.mem.containsAtLeast(u8, command, 1, " -S "));
                }
            }).check,
        },
    });
}

test "immediate exit" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        .{
            .input = .{ .tmux = .{ .exit = "" } },
            .contains_tags = &.{.exit},
        },
        .{
            .input = .{ .tmux = .{ .exit = "" } },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                }
            }).check,
        },
    });
}

test "direct viewer accepts only the server attach block" {
    var server_viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer server_viewer.deinit();
    var server_block = testClientBlock("");
    server_block.meta.flags = 0;
    try testing.expectEqual(
        0,
        server_viewer.next(.{ .tmux = .{ .block_end = server_block } }).len,
    );
    try testing.expectEqual(State.startup_session, server_viewer.state);

    var client_viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer client_viewer.deinit();
    const actions = client_viewer.next(.{ .tmux = .{
        .block_end = testClientBlock(""),
    } });
    try testing.expectEqual(1, actions.len);
    try testing.expect(actions[0] == .exit);
    try testing.expectEqual(State.defunct, client_viewer.state);
}

test "session changed resets state" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{
        .history_line_limit = 2_000,
    });
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .handshake_ok },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "first",
            } } },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = testClientBlock("3.5a") } },
        },
        // Receive window layout with two panes (same format as "initial flow" test)
        .{
            .input = .{ .tmux = .{
                .block_end = testClientBlock(
                    \\$1 @0 1 %0 83 44 027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1] 027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1] shell
                    ,
                ),
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, v.session_id);
                    try testing.expectEqualStrings("first", v.session_name);
                    try testing.expectEqual(1, v.windows.items.len);
                    try testing.expectEqual(2, v.panes.count());
                    try testing.expectEqualStrings("3.5a", v.tmux_version);

                    for (actions) |action| switch (action) {
                        .windows => |windows| {
                            // The action must reference viewer-owned state,
                            // not the temporary list used while parsing.
                            try testing.expectEqual(v.windows.items.ptr, windows.ptr);
                            try testing.expectEqual(v.windows.items.len, windows.len);
                            try testing.expectEqual(@as(usize, 0), windows[0].id);
                            return;
                        },
                        else => {},
                    };
                    return error.TestExpectedWindowsAction;
                }
            }).check,
        },
        // tmux queues session-change notifications after all command response
        // blocks that preceded the switch. Drain the pane hydration group
        // before injecting the notification below.
        .{
            .input = .{ .tmux = .{ .block_end = testClientBlock(
                \\%0;83;20;0;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;;;0;0;19;8,16;0;shell
                \\%1;83;23;0;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;;;0;0;22;8,16;1;editor
                ,
            ) } },
        },
        .{ .input = .{ .tmux = .{ .block_end = testClientBlock("") } } },
        .{ .input = .{ .tmux = .{ .block_end = testClientBlock("") } } },
        .{ .input = .{ .tmux = .{ .block_end = testClientBlock("") } } },
        .{ .input = .{ .tmux = .{ .block_end = testClientBlock("") } } },
        .{ .input = .{ .tmux = .{ .block_end = testClientBlock("") } } },
        .{ .input = .{ .tmux = .{ .block_end = testClientBlock("") } } },
        .{ .input = .{ .tmux = .{ .block_end = testClientBlock("") } } },
        .{ .input = .{ .tmux = .{ .block_end = testClientBlock("") } } },
        // Now session changes - should reset everything but keep version
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 2,
                .name = "second",
            } } },
            .contains_tags = &.{ .windows, .command },
            .contains_command = "list-windows",
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    // Session ID should be updated
                    try testing.expectEqual(2, v.session_id);
                    try testing.expectEqualStrings("second", v.session_name);
                    // Windows should be cleared (empty windows action sent)
                    var found_empty_windows = false;
                    for (actions) |action| {
                        if (action == .windows and action.windows.len == 0) {
                            found_empty_windows = true;
                        }
                    }
                    try testing.expect(found_empty_windows);
                    // Old windows should be cleared
                    try testing.expectEqual(0, v.windows.items.len);
                    // Old panes should be cleared
                    try testing.expectEqual(0, v.panes.count());
                    // Version should still be preserved
                    try testing.expectEqualStrings("3.5a", v.tmux_version);
                    try testing.expectEqual(2_000, v.options.history_line_limit.?);
                }
            }).check,
        },
        // Receive new window layout for new session (same layout, different session/window)
        // Uses same pane IDs 0,1 - they should be re-created since old panes were cleared
        .{
            .input = .{ .tmux = .{
                .block_end = testClientBlock(
                    \\$2 @1 1 %0 83 44 027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1] 027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1] shell
                    ,
                ),
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(2, v.session_id);
                    try testing.expectEqual(1, v.windows.items.len);
                    try testing.expectEqual(1, v.windows.items[0].id);
                    // Panes 0 and 1 should be created (fresh, since old ones were cleared)
                    try testing.expectEqual(2, v.panes.count());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = "" } },
            .contains_tags = &.{.exit},
        },
    });
}

test "session changed with pending commands fails closed" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    _ = viewer.next(.handshake_ok);
    const startup = viewer.next(.{ .tmux = .{ .session_changed = .{
        .id = 1,
        .name = "first",
    } } });
    try testing.expectEqual(2, startup.len);
    try testing.expect(startup[0] == .command);
    try testing.expect(startup[1] == .command);
    try testing.expectEqual(2, viewer.sent_command_count);

    const actions = viewer.next(.{ .tmux = .{ .session_changed = .{
        .id = 2,
        .name = "second",
    } } });
    try testing.expectEqual(1, actions.len);
    try testing.expect(actions[0] == .exit);
    try testing.expectEqual(State.defunct, viewer.state);
}

test "initial session name allocation failure is atomic" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var viewer = try Viewer.init(testing.io, failing.allocator(), .{});
    var viewer_live = true;
    defer if (viewer_live) viewer.deinit();

    _ = viewer.next(.handshake_ok);
    failing.fail_index = failing.alloc_index;
    const actions = viewer.next(.{ .tmux = .{ .session_changed = .{
        .id = 42,
        .name = "not-retained",
    } } });

    try testing.expectEqual(1, actions.len);
    try testing.expect(actions[0] == .exit);
    try testing.expectEqual(State.defunct, viewer.state);
    try testing.expectEqual(0, viewer.session_id);
    try testing.expectEqualStrings("", viewer.session_name);

    viewer.deinit();
    viewer_live = false;
    try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "initial flow" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{
        .history_line_limit = 2_000,
    });
    defer viewer.deinit();
    var pre_topology_prefix = [_]u8{0xE2};

    try testViewer(&viewer, &.{
        .{ .input = .handshake_ok },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 42,
                .name = "main",
            } } },
            .contains_command = "display-message",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(42, v.session_id);
                    try testing.expectEqualStrings("main", v.session_name);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .block_end = testClientBlock("3.5a") } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqualStrings("3.5a", v.tmux_version);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .output = .{
                .pane_id = 1,
                .data = &pre_topology_prefix,
            } } },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(0, actions.len);
                    try testing.expectEqual(1, v.untracked_utf8.get(1).?.len);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{
                .block_end = testClientBlock(
                    \\$0 @0 1 %0 83 44 027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1] 027b,83x44,0,0[83x20,0,0,0,83x23,0,21,1] shell
                    ,
                ),
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    var found_command = false;
                    for (actions) |action| switch (action) {
                        .windows => |windows| {
                            try testing.expectEqual(v.windows.items.ptr, windows.ptr);
                            try testing.expectEqual(v.windows.items.len, windows.len);
                        },
                        .command => found_command = true,
                        else => {},
                    };
                    try testing.expect(found_command);
                }
            }).check,
            .check_command = (struct {
                fn check(_: *Viewer, command: []const u8) anyerror!void {
                    try testing.expect(std.mem.startsWith(u8, command, "list-panes -s"));
                    try testing.expectEqual(8, std.mem.count(u8, command, "capture-pane"));
                    try testing.expectEqual(8, std.mem.count(u8, command, " ; "));
                    try testing.expectEqual(4, std.mem.count(u8, command, "-t %0"));
                    try testing.expectEqual(4, std.mem.count(u8, command, "-t %1"));
                    try testing.expectEqual(6, std.mem.count(u8, command, " -N"));
                    try testing.expectEqual(2, std.mem.count(u8, command, " -S -2000 "));
                }
            }).check,
        },
    });

    const pane_state =
        \\%0;83;20;8;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;;;1;0;19;8,16;zsh;/Users/test/shell;one
        \\%1;83;23;0;0;1;;;;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;;;0;0;22;8,16;nvim;/Users/test/editor
    ;
    const first_responses = [_][]const u8{
        pane_state,
        "Hello, world!",
        "",
    };
    for (first_responses, 0..) |response, index| {
        const actions = viewer.next(.{ .tmux = .{ .block_end = testClientBlock(response) } });
        if (index == 0) {
            try testing.expectEqual(1, actions.len);
            try testing.expect(actions[0] == .windows);
            try testing.expectEqualStrings("zsh", viewer.panes.get(0).?.current_command);
            try testing.expectEqualStrings("/Users/test/shell;one", viewer.panes.get(0).?.current_path);
            try testing.expectEqualStrings("nvim", viewer.panes.get(1).?.current_command);
            try testing.expectEqualStrings("/Users/test/editor", viewer.panes.get(1).?.current_path);
        } else {
            try testing.expectEqual(0, actions.len);
        }
    }

    // This output predates the canonical visible snapshot, so it must not be
    // rendered independently and duplicated by that snapshot.
    var superseded_output = "superseded".*;
    try testing.expectEqual(0, viewer.next(.{ .tmux = .{ .output = .{
        .pane_id = 0,
        .data = &superseded_output,
    } } }).len);

    const remaining_responses = [_][]const u8{
        "snapshot",
        "",
        "first visible row",
        "",
        "first visible row",
        "",
    };
    const expected_changes = [_]?usize{ null, 0, null, null, null, 1 };
    for (remaining_responses, expected_changes) |response, expected_change| {
        const actions = viewer.next(.{ .tmux = .{ .block_end = testClientBlock(response) } });
        if (expected_change) |id| {
            try testing.expectEqual(1, actions.len);
            try testing.expectEqual(id, actions[0].pane_changed.pane_id);
            try testing.expectEqual(Viewer.Pane.Phase.live, viewer.panes.get(id).?.phase);
        } else {
            try testing.expectEqual(0, actions.len);
        }
    }

    try testing.expect(viewer.command_queue.empty());
    try testing.expectEqual(0, viewer.sent_command_count);
    const pane = viewer.panes.get(0).?;
    try testing.expectEqual(Viewer.Pane.Phase.live, pane.phase);
    try testing.expectEqual(ScreenSet.Key.primary, pane.active_screen);
    const history = try pane.terminal_owner.terminal.screens.active.dumpStringAlloc(
        testing.allocator,
        .{ .history = .{} },
    );
    defer testing.allocator.free(history);
    try testing.expect(std.mem.containsAtLeast(u8, history, 1, "Hello, world!"));

    var new_output = "new\\134output".*;
    const changed = viewer.next(.{ .tmux = .{ .output = .{
        .pane_id = 0,
        .data = &new_output,
    } } });
    try testing.expectEqual(1, changed.len);
    try testing.expectEqual(0, changed[0].pane_changed.pane_id);
    try testing.expectEqual(Viewer.Pane.Phase.live, pane.phase);
    const active = try pane.terminal_owner.terminal.screens.active.dumpStringAlloc(
        testing.allocator,
        .{ .active = .{} },
    );
    defer testing.allocator.free(active);
    try testing.expect(!std.mem.containsAtLeast(u8, active, 1, "superseded"));
    try testing.expect(std.mem.containsAtLeast(u8, active, 1, "new\\output"));

    const fresh_pane = viewer.panes.get(1).?;
    try testing.expect(
        fresh_pane.terminal_owner.terminal.screens.active.pages.getBottomRight(.history) == null,
    );
    const fresh_active = try fresh_pane.terminal_owner.terminal.screens.active.dumpStringAlloc(
        testing.allocator,
        .{ .active = .{} },
    );
    defer testing.allocator.free(fresh_active);
    try testing.expectEqualStrings("first visible row", fresh_active);

    var pre_topology_suffix = [_]u8{ 0x82, 0xAC };
    const fresh_changed = viewer.next(.{ .tmux = .{ .output = .{
        .pane_id = 1,
        .data = &pre_topology_suffix,
    } } });
    try testing.expectEqual(1, fresh_changed.len);
    try testing.expectEqual(1, fresh_changed[0].pane_changed.pane_id);
    const fresh_after_suffix = try fresh_pane.terminal_owner.terminal.screens.active.dumpStringAlloc(
        testing.allocator,
        .{ .active = .{} },
    );
    defer testing.allocator.free(fresh_after_suffix);
    try testing.expect(std.mem.containsAtLeast(u8, fresh_after_suffix, 1, "€"));

    var ignored_output = "ignored\\134output".*;
    try testing.expectEqual(0, viewer.next(.{ .tmux = .{ .output = .{
        .pane_id = 999,
        .data = &ignored_output,
    } } }).len);
    try testing.expectEqualStrings("ignored\\134output", &ignored_output);
}

test "untracked UTF-8 allocation failure exits the viewer" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();
    viewer.state = .command_queue;

    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    failing.fail_index = failing.alloc_index;
    const original_alloc = viewer.alloc;
    defer viewer.alloc = original_alloc;
    viewer.alloc = failing.allocator();

    var prefix = [_]u8{0xE2};
    const actions = viewer.next(.{ .tmux = .{ .output = .{
        .pane_id = 1,
        .data = &prefix,
    } } });
    try testing.expectEqual(1, actions.len);
    try testing.expect(actions[0] == .exit);
    try testing.expectEqual(State.defunct, viewer.state);
}

test "live output preserves UTF-8 split across notifications" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();
    viewer.state = .command_queue;

    const pane = try Viewer.Pane.init(testing.io, testing.allocator, .{
        .cols = 5,
        .rows = 1,
    });
    pane.phase = .live;
    viewer.panes.put(testing.allocator, 1, pane) catch |err| {
        pane.deinit(testing.allocator);
        return err;
    };

    var first = [_]u8{0xE2};
    var second = [_]u8{0x82};
    var third = [_]u8{0xAC};
    _ = viewer.next(.{ .tmux = .{ .output = .{ .pane_id = 1, .data = &first } } });
    _ = viewer.next(.{ .tmux = .{ .output = .{ .pane_id = 1, .data = &second } } });
    _ = viewer.next(.{ .tmux = .{ .output = .{ .pane_id = 1, .data = &third } } });

    const actual = try pane.terminal_owner.terminal.plainString(testing.allocator);
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("€", actual);
}

test "live output action does not allocate" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();
    viewer.state = .command_queue;

    const pane = try Viewer.Pane.init(testing.io, testing.allocator, .{
        .cols = 5,
        .rows = 1,
    });
    pane.phase = .live;
    viewer.panes.put(testing.allocator, 1, pane) catch |err| {
        pane.deinit(testing.allocator);
        return err;
    };

    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    failing.fail_index = failing.alloc_index;
    const original_alloc = viewer.alloc;
    viewer.alloc = failing.allocator();
    defer viewer.alloc = original_alloc;

    var bytes = "X".*;
    const actions = viewer.next(.{ .tmux = .{ .output = .{
        .pane_id = 1,
        .data = &bytes,
    } } });
    try testing.expectEqual(1, actions.len);
    try testing.expectEqual(1, actions[0].pane_changed.pane_id);
    const actual = try pane.terminal_owner.terminal.plainString(testing.allocator);
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("X", actual);
}

test "live output preserves CSI split across notifications" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();
    viewer.state = .command_queue;

    const pane = try Viewer.Pane.init(testing.io, testing.allocator, .{
        .cols = 5,
        .rows = 1,
    });
    pane.phase = .live;
    viewer.panes.put(testing.allocator, 1, pane) catch |err| {
        pane.deinit(testing.allocator);
        return err;
    };

    var first = [_]u8{0x1B};
    var second = "[1".*;
    var third = "mX".*;
    _ = viewer.next(.{ .tmux = .{ .output = .{ .pane_id = 1, .data = &first } } });
    _ = viewer.next(.{ .tmux = .{ .output = .{ .pane_id = 1, .data = &second } } });
    _ = viewer.next(.{ .tmux = .{ .output = .{ .pane_id = 1, .data = &third } } });

    const cell = pane.terminal_owner.terminal.screens.active.pages.getCell(.{
        .screen = .{ .x = 0, .y = 0 },
    }).?.cell;
    try testing.expectEqual(@as(u21, 'X'), cell.codepoint());
    try testing.expect(cell.style_id != 0);
    try testing.expect(pane.terminal_owner.terminal.screens.active.cursor.style.flags.bold);
}

test "hydration seeds pending VT state before live output" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();
    viewer.state = .command_queue;

    const pane = try Viewer.Pane.init(testing.io, testing.allocator, .{
        .cols = 5,
        .rows = 1,
    });
    viewer.panes.put(testing.allocator, 1, pane) catch |err| {
        pane.deinit(testing.allocator);
        return err;
    };

    try testing.expect(try viewer.receivedPanePending(1, "\\033[1"));
    var suffix = "mX".*;
    _ = viewer.next(.{ .tmux = .{ .output = .{
        .pane_id = 1,
        .data = &suffix,
    } } });

    const cell = pane.terminal_owner.terminal.screens.active.pages.getCell(.{
        .screen = .{ .x = 0, .y = 0 },
    }).?.cell;
    try testing.expectEqual(Viewer.Pane.Phase.live, pane.phase);
    try testing.expectEqual(@as(u21, 'X'), cell.codepoint());
    try testing.expect(cell.style_id != 0);
}

test "hydration carries split UTF-8 past an empty pending capture" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();
    viewer.state = .command_queue;

    const pane = try Viewer.Pane.init(testing.io, testing.allocator, .{
        .cols = 5,
        .rows = 1,
    });
    viewer.panes.put(testing.allocator, 1, pane) catch |err| {
        pane.deinit(testing.allocator);
        return err;
    };

    var prefix = [_]u8{0xE2};
    _ = viewer.next(.{ .tmux = .{ .output = .{
        .pane_id = 1,
        .data = &prefix,
    } } });
    try testing.expect(try viewer.receivedPanePending(1, ""));

    var suffix = [_]u8{ 0x82, 0xAC };
    _ = viewer.next(.{ .tmux = .{ .output = .{
        .pane_id = 1,
        .data = &suffix,
    } } });

    const actual = try pane.terminal_owner.terminal.plainString(testing.allocator);
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("€", actual);
}

test "hydration command errors do not become terminal content" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();
    viewer.state = .command_queue;

    const pane = try Viewer.Pane.init(testing.io, testing.allocator, .{
        .cols = 10,
        .rows = 2,
    });
    viewer.panes.put(testing.allocator, 1, pane) catch |err| {
        pane.deinit(testing.allocator);
        return err;
    };

    try viewer.queueCommands(&.{.{ .pane_history = .{
        .id = 1,
        .line_limit = null,
    } }});
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var queued_actions: std.ArrayList(Viewer.Action) = .empty;
    try viewer.appendQueuedCommandActionsWithAllocator(
        &queued_actions,
        arena.allocator(),
    );

    const actions = viewer.next(.{ .tmux = .{ .block_err = testClientBlock("no such pane") } });
    try testing.expectEqual(1, actions.len);
    try testing.expect(actions[0] == .exit);
    try testing.expectEqual(Viewer.Pane.Phase.initial_hydrating, pane.phase);
    const actual = try pane.terminal_owner.terminal.plainString(testing.allocator);
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings("", actual);
}

test "direct viewer server block does not consume a command" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    _ = viewer.next(.handshake_ok);
    _ = viewer.next(.{ .tmux = .{ .session_changed = .{
        .id = 1,
        .name = "main",
    } } });
    try testing.expectEqual(2, viewer.sent_command_count);

    var server_block = testClientBlock("server");
    server_block.meta.flags = 0;
    try testing.expectEqual(
        0,
        viewer.next(.{ .tmux = .{ .block_end = server_block } }).len,
    );
    try testing.expectEqual(2, viewer.sent_command_count);
}

test "direct viewer group error preserves later group" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();
    viewer.state = .command_queue;

    try viewer.command_queue.ensureUnusedCapacity(testing.allocator, 3);
    for ([_]bool{ false, true, true }, 0..) |group_end, i| {
        const text = try testing.allocator.dupe(
            u8,
            if (i == 2) "later" else "group",
        );
        viewer.command_queue.appendAssumeCapacity(.{
            .command = .{ .user = text },
            .group_end = group_end,
        });
    }
    viewer.sent_command_count = 3;

    try testing.expectEqual(
        0,
        viewer.next(.{ .tmux = .{
            .block_err = testClientBlock("failed"),
        } }).len,
    );
    try testing.expectEqual(State.command_queue, viewer.state);
    try testing.expectEqual(1, viewer.command_queue.len());
    try testing.expectEqual(1, viewer.sent_command_count);

    try testing.expectEqual(
        0,
        viewer.next(.{ .tmux = .{
            .block_end = testClientBlock("ok"),
        } }).len,
    );
    try testing.expect(viewer.command_queue.empty());
    try testing.expectEqual(0, viewer.sent_command_count);
}

test "zoomed geometry follows visible layout" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    const full_layout = "607b,83x44,0,0[83x22,0,0,0,83x21,0,23,1]";
    try testViewer(&viewer, &.{
        .{ .input = .handshake_ok },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "zoomed",
            } } },
            .contains_command = "display-message",
        },
        .{
            .input = .{ .tmux = .{ .block_end = testClientBlock("3.1") } },
        },
        .{
            .input = .{ .tmux = .{
                .block_end = testClientBlock("$1 @0 1 %0 83 44 " ++ full_layout ++ " b7dd,83x44,0,0,0 shell"),
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(v.windows.items[0].is_zoomed);
                    try testing.expectEqual(83, v.panes.get(0).?.terminal_owner.terminal.cols);
                    try testing.expectEqual(44, v.panes.get(0).?.terminal_owner.terminal.rows);
                    try testing.expectEqual(83, v.panes.get(1).?.terminal_owner.terminal.cols);
                    try testing.expectEqual(21, v.panes.get(1).?.terminal_owner.terminal.rows);
                }
            }).check,
        },
    });

    for (0..9) |index| {
        const actions = viewer.next(.{ .tmux = .{ .block_end = testClientBlock("") } });
        const expected_change: ?usize = switch (index) {
            4 => 0,
            8 => 1,
            else => null,
        };
        if (expected_change) |id| {
            try testing.expectEqual(1, actions.len);
            try testing.expectEqual(id, actions[0].pane_changed.pane_id);
        } else {
            try testing.expectEqual(0, actions.len);
        }
    }

    const pane_0 = viewer.panes.get(0).?;
    const pane_1 = viewer.panes.get(1).?;
    const terminal_0 = &pane_0.terminal_owner.terminal;
    const terminal_1 = &pane_1.terminal_owner.terminal;
    try testing.expectEqual(Viewer.Pane.Phase.live, pane_0.phase);
    try testing.expectEqual(Viewer.Pane.Phase.live, pane_1.phase);

    const actions = viewer.next(.{ .tmux = .{ .layout_change = .{
        .window_id = 0,
        .layout = full_layout,
        .visible_layout = "b7de,83x44,0,0,1",
        .raw_flags = "*",
    } } });

    // Zoom moved to pane 1 without a client resize from this Viewer, so both
    // shown panes take the new geometry and are recaptured. tmux 3.1 can't
    // pause a pane, so each recapture is the snapshot group itself.
    try testing.expectEqual(3, actions.len);
    try testing.expect(actions[0] == .windows);
    try testing.expect(actions[1] == .command);
    try testing.expect(actions[2] == .command);
    try testing.expect(viewer.windows.items[0].is_zoomed);
    try testing.expectEqual(1, viewer.windows.items[0].active_pane_id);
    try testing.expectEqual(83, viewer.windows.items[0].width);
    try testing.expectEqual(44, viewer.windows.items[0].height);
    try testing.expectEqual(83, viewer.panes.get(0).?.terminal_owner.terminal.cols);
    try testing.expectEqual(22, viewer.panes.get(0).?.terminal_owner.terminal.rows);
    try testing.expectEqual(83, viewer.panes.get(1).?.terminal_owner.terminal.cols);
    try testing.expectEqual(44, viewer.panes.get(1).?.terminal_owner.terminal.rows);
    try testing.expectEqual(pane_0, viewer.panes.get(0).?);
    try testing.expectEqual(pane_1, viewer.panes.get(1).?);
    try testing.expectEqual(terminal_0, &viewer.panes.get(0).?.terminal_owner.terminal);
    try testing.expectEqual(terminal_1, &viewer.panes.get(1).?.terminal_owner.terminal);
    try testing.expectEqual(Viewer.Pane.Phase.refreshing, pane_0.phase);
    try testing.expectEqual(Viewer.Pane.Phase.refreshing, pane_1.phase);

    const successor_actions = viewer.next(.{ .tmux = .{ .layout_change = .{
        .window_id = 0,
        .layout = "9c1f,83x44,0,0{41x44,0,0,1,41x44,42,0,2}",
        .visible_layout = "b7de,83x44,0,0,1",
        .raw_flags = "*",
    } } });
    try testing.expect(successor_actions.len > 0);
    try testing.expect(successor_actions[0] == .windows);
    try testing.expect(!viewer.panes.contains(0));
    try testing.expect(viewer.panes.contains(1));
    try testing.expect(viewer.panes.contains(2));
    try testing.expectEqual(1, viewer.windows.items[0].active_pane_id);

    const duplicate_active = viewer.next(.{ .tmux = .{ .window_pane_changed = .{
        .window_id = 0,
        .pane_id = 1,
    } } });
    try testing.expectEqual(0, duplicate_active.len);
}

test "layout change" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();
    var undiscovered_prefix = [_]u8{0xE2};

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .handshake_ok },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = testClientBlock("3.5a") } },
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = .{
                .block_end = testClientBlock(
                    \\$0 @0 1 %0 83 44 b7dd,83x44,0,0,0 b7dd,83x44,0,0,0 shell
                    ,
                ),
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, v.windows.items.len);
                    try testing.expectEqual(1, v.panes.count());
                    try testing.expect(v.panes.contains(0));
                }
            }).check,
        },
        // Complete all capture-pane commands for pane 0 (primary and alternate)
        // plus pane_state
        .{ .input = .{ .tmux = .{ .block_end = testClientBlock("") } } },
        .{ .input = .{ .tmux = .{ .block_end = testClientBlock("") } } },
        .{ .input = .{ .tmux = .{ .block_end = testClientBlock("") } } },
        .{ .input = .{ .tmux = .{ .block_end = testClientBlock("") } } },
        .{ .input = .{ .tmux = .{ .block_end = testClientBlock("") } } },
        // A partial layout notification cannot prove that output for an
        // undiscovered pane is stale; only a full list-windows cut can.
        .{
            .input = .{ .tmux = .{ .output = .{
                .pane_id = 99,
                .data = &undiscovered_prefix,
            } } },
        },
        // Now send a layout_change that splits into two panes
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .visible_layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .raw_flags = "*",
            } } },
            .contains_tags = &.{.windows},
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Should still have 1 window
                    try testing.expectEqual(1, v.windows.items.len);
                    // Should now have 2 panes (0 and 2)
                    try testing.expectEqual(2, v.panes.count());
                    try testing.expect(v.panes.contains(0));
                    try testing.expect(v.panes.contains(2));
                    // Commands should be queued for the new pane (4
                    // capture-pane + 1 pane_state), and pane 0, which the
                    // split resized, is recaptured starting with a pause.
                    try testing.expectEqual(6, v.command_queue.len());
                    try testing.expectEqual(
                        Viewer.Pane.Phase.refresh_pausing,
                        v.panes.get(0).?.phase,
                    );
                    try testing.expectEqual(1, v.untracked_utf8.get(99).?.len);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = "" } },
            .contains_tags = &.{.exit},
        },
    });
}

test "layout_change emits a new group while another group is pending" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .handshake_ok },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = testClientBlock("3.5a") } },
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = .{
                .block_end = testClientBlock(
                    \\$0 @0 1 %0 83 44 b7dd,83x44,0,0,0 b7dd,83x44,0,0,0 shell
                    ,
                ),
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(!v.command_queue.empty());
                }
            }).check,
        },
        // Do NOT complete capture-pane commands. A new pane still produces an
        // independent hydration group immediately.
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .visible_layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .raw_flags = "*",
            } } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(2, v.panes.count());
                    try testing.expectEqual(2, actions.len);
                    try testing.expectEqual(v.command_queue.len(), v.sent_command_count);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = "" } },
            .contains_tags = &.{.exit},
        },
    });
}

test "layout_change returns command when queue was empty" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .handshake_ok },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = testClientBlock("3.5a") } },
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = .{
                .block_end = testClientBlock(
                    \\$0 @0 1 %0 83 44 b7dd,83x44,0,0,0 b7dd,83x44,0,0,0 shell
                    ,
                ),
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete all capture-pane commands for pane 0
        .{ .input = .{ .tmux = .{ .block_end = testClientBlock("") } } },
        .{ .input = .{ .tmux = .{ .block_end = testClientBlock("") } } },
        .{ .input = .{ .tmux = .{ .block_end = testClientBlock("") } } },
        .{ .input = .{ .tmux = .{ .block_end = testClientBlock("") } } },
        // Queue should now be empty
        .{
            .input = .{ .tmux = .{ .block_end = testClientBlock("") } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
        // Now send a layout_change that splits into two panes.
        // This should return a command action since we're queuing commands
        // for the new pane and the queue was empty.
        .{
            .input = .{ .tmux = .{ .layout_change = .{
                .window_id = 0,
                .layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .visible_layout = "e07b,83x44,0,0[83x22,0,0,0,83x21,0,23,2]",
                .raw_flags = "*",
            } } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(2, v.panes.count());
                    try testing.expect(!v.command_queue.empty());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = "" } },
            .contains_tags = &.{.exit},
        },
    });
}

fn seedWindowCloseTestViewer(viewer: *Viewer) !void {
    viewer.state = .command_queue;
    viewer.session_id = 42;
    const initial_topology =
        \\$42 @0 1 %0 83 44 b7dd,83x44,0,0,0 b7dd,83x44,0,0,0 zero
        \\$42 @1 0 %1 83 44 b7de,83x44,0,0,1 b7de,83x44,0,0,1 one
    ;
    {
        var arena = viewer.action_arena.promote(viewer.alloc);
        defer viewer.action_arena = arena.state;
        var actions: std.ArrayList(Viewer.Action) = .empty;
        try viewer.receivedListWindows(
            arena.allocator(),
            &actions,
            initial_topology,
        );
    }
    viewer.command_queue.clear();
    viewer.sent_command_count = 0;
}

test "window rename replaces the owned name and publishes topology" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();
    try seedWindowCloseTestViewer(&viewer);

    var actions = viewer.next(.{ .tmux = .{ .window_renamed = .{
        .id = 0,
        .name = "editor window",
    } } });
    try testing.expectEqual(1, actions.len);
    try testing.expect(actions[0] == .windows);
    try testing.expectEqualStrings("editor window", viewer.windows.items[0].name);

    actions = viewer.next(.{ .tmux = .{ .window_renamed = .{
        .id = 0,
        .name = "editor window",
    } } });
    try testing.expectEqual(0, actions.len);

    actions = viewer.next(.{ .tmux = .{ .window_renamed = .{
        .id = 0,
        .name = "",
    } } });
    try testing.expectEqual(1, actions.len);
    try testing.expectEqualStrings("", viewer.windows.items[0].name);

    actions = viewer.next(.{ .tmux = .{ .window_renamed = .{
        .id = 99,
        .name = "unknown",
    } } });
    try testing.expectEqual(0, actions.len);
}

test "list-windows reconstructs multiline names without another command" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();
    try seedWindowCloseTestViewer(&viewer);

    try viewer.queueCommands(&.{.list_windows});
    {
        var arena = viewer.action_arena.promote(viewer.alloc);
        defer viewer.action_arena = arena.state;
        var queued_actions: std.ArrayList(Viewer.Action) = .empty;
        try viewer.appendQueuedCommandActionsWithAllocator(
            &queued_actions,
            arena.allocator(),
        );
    }

    const rich =
        "$42 @0 1 %0 83 44 b7dd,83x44,0,0,0 " ++
        "b7dd,83x44,0,0,0 editor\nworkspace\n\n" ++
        "$42 @1 0 %1 83 44 b7de,83x44,0,0,1 " ++
        "b7de,83x44,0,0,1 logs";
    const actions = viewer.next(.{ .command_complete = .{ .success = rich } });
    try testing.expectEqual(1, actions.len);
    try testing.expect(actions[0] == .windows);
    try testing.expectEqual(2, viewer.windows.items.len);
    try testing.expectEqualStrings(
        "editor\nworkspace\n",
        viewer.windows.items[0].name,
    );
    try testing.expectEqualStrings("logs", viewer.windows.items[1].name);
}

test "invalid list-windows response fails without publishing topology" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();
    try seedWindowCloseTestViewer(&viewer);

    try viewer.queueCommands(&.{.list_windows});
    {
        var arena = viewer.action_arena.promote(viewer.alloc);
        defer viewer.action_arena = arena.state;
        var queued_actions: std.ArrayList(Viewer.Action) = .empty;
        try viewer.appendQueuedCommandActionsWithAllocator(
            &queued_actions,
            arena.allocator(),
        );
    }

    const actions = viewer.next(.{
        .command_complete = .{ .success = "garbage" },
    });
    try testing.expectEqual(1, actions.len);
    try testing.expect(actions[0] == .exit);
    try testing.expectEqual(State.defunct, viewer.state);
    try testing.expectEqual(2, viewer.windows.items.len);
    try testing.expectEqualStrings("zero", viewer.windows.items[0].name);
    try testing.expectEqualStrings("one", viewer.windows.items[1].name);
}

test "window_close from another session does not change current topology" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();
    try seedWindowCloseTestViewer(&viewer);

    const actions = viewer.next(.{ .tmux = .{ .window_close = .{ .id = 1 } } });
    try testing.expectEqual(0, actions.len);
    try testing.expectEqual(2, viewer.windows.items.len);
    try testing.expectEqual(2, viewer.panes.count());
    try testing.expectEqual(0, viewer.command_queue.len());
    try testing.expectEqual(0, viewer.sent_command_count);
}

test "unlinked_window_close removes once without commands" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();
    try seedWindowCloseTestViewer(&viewer);

    var actions = viewer.next(.{ .tmux = .{ .unlinked_window_close = .{ .id = 1 } } });
    try testing.expectEqual(1, actions.len);
    try testing.expect(actions[0] == .windows);
    try testing.expectEqual(1, viewer.windows.items.len);
    try testing.expectEqual(0, viewer.windows.items[0].id);
    try testing.expectEqual(1, viewer.panes.count());
    try testing.expect(viewer.panes.contains(0));
    try testing.expect(!viewer.panes.contains(1));
    try testing.expectEqual(0, viewer.command_queue.len());
    try testing.expectEqual(0, viewer.sent_command_count);

    actions = viewer.next(.{ .tmux = .{ .unlinked_window_close = .{ .id = 1 } } });
    try testing.expectEqual(0, actions.len);
    try testing.expectEqual(1, viewer.windows.items.len);
    try testing.expectEqual(1, viewer.panes.count());
    try testing.expectEqual(0, viewer.command_queue.len());
}

test "session active-window change precedes unlinked_window_close" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();
    try seedWindowCloseTestViewer(&viewer);

    var actions = viewer.next(.{ .tmux = .{ .session_window_changed = .{
        .session_id = 42,
        .window_id = 1,
    } } });
    try testing.expectEqual(1, actions.len);
    try testing.expect(actions[0] == .windows);
    try testing.expect(!viewer.windows.items[0].is_active);
    try testing.expect(viewer.windows.items[1].is_active);

    actions = viewer.next(.{ .tmux = .{ .unlinked_window_close = .{ .id = 0 } } });
    try testing.expectEqual(1, actions.len);
    try testing.expect(actions[0] == .windows);
    try testing.expectEqual(1, viewer.windows.items.len);
    try testing.expectEqual(1, viewer.windows.items[0].id);
    try testing.expect(viewer.windows.items[0].is_active);
    try testing.expectEqual(1, viewer.panes.count());
    try testing.expect(viewer.panes.contains(1));
    try testing.expectEqual(0, viewer.command_queue.len());
}

test "unlinked_window_close preserves an in-flight command group" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();
    try seedWindowCloseTestViewer(&viewer);

    try viewer.queueCommands(&.{.list_windows});
    {
        var actions: std.ArrayList(Viewer.Action) = .empty;
        try viewer.appendQueuedCommandActions(&actions);
    }
    try testing.expectEqual(1, viewer.command_queue.len());
    try testing.expectEqual(1, viewer.sent_command_count);

    const actions = viewer.next(.{ .tmux = .{ .unlinked_window_close = .{ .id = 1 } } });
    try testing.expectEqual(1, actions.len);
    try testing.expect(actions[0] == .windows);
    for (actions) |action| try testing.expect(action != .command);
    try testing.expectEqual(1, viewer.command_queue.len());
    try testing.expectEqual(1, viewer.sent_command_count);
}

test "window_add queues list_windows when queue empty" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .handshake_ok },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = testClientBlock("3.5a") } },
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = .{
                .block_end = testClientBlock(
                    \\$0 @0 1 %0 83 44 b7dd,83x44,0,0,0 b7dd,83x44,0,0,0 shell
                    ,
                ),
            } },
            .contains_tags = &.{ .windows, .command },
        },
        // Complete all capture-pane commands for pane 0
        .{ .input = .{ .tmux = .{ .block_end = testClientBlock("") } } },
        .{ .input = .{ .tmux = .{ .block_end = testClientBlock("") } } },
        .{ .input = .{ .tmux = .{ .block_end = testClientBlock("") } } },
        .{ .input = .{ .tmux = .{ .block_end = testClientBlock("") } } },
        // Queue should now be empty
        .{
            .input = .{ .tmux = .{ .block_end = testClientBlock("") } },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    try testing.expect(v.command_queue.empty());
                }
            }).check,
        },
        // Now send window_add - should trigger list-windows command
        .{
            .input = .{ .tmux = .{ .window_add = .{ .id = 1 } } },
            .contains_command = "list-windows",
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Command queue should have list_windows
                    try testing.expect(!v.command_queue.empty());
                    try testing.expectEqual(1, v.command_queue.len());
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = "" } },
            .contains_tags = &.{.exit},
        },
    });
}

test "window_add emits list_windows while another group is pending" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();

    try testViewer(&viewer, &.{
        // Initial startup
        .{ .input = .handshake_ok },
        .{
            .input = .{ .tmux = .{ .session_changed = .{
                .id = 1,
                .name = "test",
            } } },
            .contains_command = "display-message",
        },
        // Receive version response, which triggers list-windows
        .{
            .input = .{ .tmux = .{ .block_end = testClientBlock("3.5a") } },
        },
        // Receive initial window layout with one pane
        .{
            .input = .{ .tmux = .{
                .block_end = testClientBlock(
                    \\$0 @0 1 %0 83 44 b7dd,83x44,0,0,0 b7dd,83x44,0,0,0 shell
                    ,
                ),
            } },
            .contains_tags = &.{ .windows, .command },
            .check = (struct {
                fn check(v: *Viewer, _: []const Viewer.Action) anyerror!void {
                    // Queue should have capture-pane commands
                    try testing.expect(!v.command_queue.empty());
                }
            }).check,
        },
        // Do NOT complete capture-pane commands. The independent window
        // refresh is still emitted immediately.
        .{
            .input = .{ .tmux = .{ .window_add = .{ .id = 1 } } },
            .contains_command = "list-windows",
            .check = (struct {
                fn check(v: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, actions.len);
                    try testing.expectEqual(v.command_queue.len(), v.sent_command_count);
                }
            }).check,
        },
        // Finish hydration. The already-emitted window refresh is not emitted
        // a second time.
        .{ .input = .{ .tmux = .{ .block_end = testClientBlock("") } } },
        .{ .input = .{ .tmux = .{ .block_end = testClientBlock("") } } },
        .{ .input = .{ .tmux = .{ .block_end = testClientBlock("") } } },
        .{ .input = .{ .tmux = .{ .block_end = testClientBlock("") } } },
        .{
            .input = .{ .tmux = .{ .block_end = testClientBlock("") } },
            .check = (struct {
                fn check(_: *Viewer, actions: []const Viewer.Action) anyerror!void {
                    try testing.expectEqual(1, actions.len);
                    try testing.expectEqual(0, actions[0].pane_changed.pane_id);
                }
            }).check,
        },
        .{
            .input = .{ .tmux = .{ .exit = "" } },
            .contains_tags = &.{.exit},
        },
    });
}

test "alternate pane hydration restores canonical screens" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();
    viewer.state = .command_queue;

    const pane = try Viewer.Pane.init(testing.io, testing.allocator, .{
        .cols = 20,
        .rows = 4,
    });
    viewer.panes.put(testing.allocator, 7, pane) catch |err| {
        pane.deinit(testing.allocator);
        return err;
    };

    _ = try viewer.receivedPaneState(
        null,
        "%7;20;4;5;2;1;bar;;1;1;3;1;0;1;0;0;1;0;0;0;0;0;;;1;1;3;8,16;nvim;/work/editor",
    );
    try testing.expectEqual(5, pane.cursor.?.x);
    try testing.expectEqual(2, pane.cursor.?.y);
    try viewer.receivedPaneHistory(7, "older");
    try viewer.receivedPaneSavedVisible(7, "primary");
    try viewer.receivedPaneVisible(7, "alternate\nsecond");
    try testing.expectEqual(5, pane.cursor.?.x);
    try testing.expectEqual(2, pane.cursor.?.y);
    try testing.expect(try viewer.receivedPanePending(7, ""));

    try testing.expectEqual(Viewer.Pane.Phase.live, pane.phase);
    try testing.expectEqual(ScreenSet.Key.alternate, pane.active_screen);
    try testing.expectEqual(pane.terminal_owner.terminal.screens.get(.alternate).?, pane.terminal_owner.terminal.screens.active);
    try testing.expectEqual(5, pane.terminal_owner.terminal.screens.active.cursor.x);
    try testing.expectEqual(2, pane.terminal_owner.terminal.screens.active.cursor.y);
    try testing.expectEqual(3, pane.terminal_owner.terminal.screens.get(.primary).?.cursor.x);
    try testing.expectEqual(1, pane.terminal_owner.terminal.screens.get(.primary).?.cursor.y);
    try testing.expect(pane.terminal_owner.terminal.modes.get(.origin));

    const primary = try pane.terminal_owner.terminal.screens.get(.primary).?.dumpStringAlloc(
        testing.allocator,
        .{ .active = .{} },
    );
    defer testing.allocator.free(primary);
    try testing.expectEqualStrings("primary", primary);

    const alternate = try pane.terminal_owner.terminal.screens.get(.alternate).?.dumpStringAlloc(
        testing.allocator,
        .{ .active = .{} },
    );
    defer testing.allocator.free(alternate);
    try testing.expectEqualStrings("alternate\nsecond", alternate);
}

test "visible snapshot preserves styled trailing cells" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();
    viewer.state = .command_queue;

    const pane = try Viewer.Pane.init(testing.io, testing.allocator, .{
        .cols = 5,
        .rows = 1,
    });
    viewer.panes.put(testing.allocator, 1, pane) catch |err| {
        pane.deinit(testing.allocator);
        return err;
    };

    try viewer.receivedPaneVisible(1, "\x1b[41mABC  ");
    try testing.expect(try viewer.receivedPanePending(1, ""));

    const screen = pane.terminal_owner.terminal.screens.active;
    const first = screen.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?.cell;
    const last = screen.pages.getCell(.{ .screen = .{ .x = 4, .y = 0 } }).?.cell;
    try testing.expect(first.style_id != 0);
    try testing.expectEqual(first.style_id, last.style_id);
}

test "history capture style does not seed visible snapshot blanks" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();
    viewer.state = .command_queue;

    const pane = try Viewer.Pane.init(testing.io, testing.allocator, .{
        .cols = 5,
        .rows = 2,
    });
    pane.has_history = true;
    viewer.panes.put(testing.allocator, 1, pane) catch |err| {
        pane.deinit(testing.allocator);
        return err;
    };

    try viewer.receivedPaneHistory(1, "\x1b[48;2;30;30;30mH");
    try viewer.receivedPaneVisible(1, "A");

    const screen = pane.terminal_owner.terminal.screens.active;
    const written = screen.pages.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?.cell;
    const trailing = screen.pages.getCell(.{ .active = .{ .x = 1, .y = 0 } }).?.cell;
    const blank = screen.pages.getCell(.{ .active = .{ .x = 0, .y = 1 } }).?.cell;
    try testing.expectEqual(@as(u21, 'A'), written.codepoint());
    try testing.expect(trailing.isZero());
    try testing.expect(blank.isZero());
}

test "pane refresh is atomic when transport submission fails" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();
    viewer.state = .command_queue;

    const pane = try Viewer.Pane.init(testing.io, testing.allocator, .{
        .cols = 10,
        .rows = 2,
    });
    pane.phase = .live;
    viewer.panes.put(testing.allocator, 1, pane) catch |err| {
        pane.deinit(testing.allocator);
        return err;
    };

    const Reject = struct {
        pane: *Viewer.Pane,

        pub fn submitPaneRefresh(
            self: @This(),
            members: []const []const u8,
        ) !void {
            try testing.expectEqual(Viewer.Pane.Phase.refreshing, self.pane.phase);
            try testing.expectEqual(5, members.len);
            return error.OutOfMemory;
        }
    };

    try testing.expectError(
        error.OutOfMemory,
        viewer.refreshPane(1, Reject{ .pane = pane }),
    );
    try testing.expectEqual(Viewer.Pane.Phase.live, pane.phase);
    try testing.expect(viewer.command_queue.empty());
    try testing.expectEqual(0, viewer.sent_command_count);
}

test "targeted pane refresh preserves protocol state and isolates concurrent groups" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();
    viewer.state = .command_queue;

    const pane_1 = try Viewer.Pane.init(testing.io, testing.allocator, .{
        .cols = 10,
        .rows = 2,
    });
    pane_1.phase = .live;
    viewer.panes.put(testing.allocator, 1, pane_1) catch |err| {
        pane_1.deinit(testing.allocator);
        return err;
    };
    const pane_2 = try Viewer.Pane.init(testing.io, testing.allocator, .{
        .cols = 11,
        .rows = 2,
    });
    pane_2.phase = .live;
    viewer.panes.put(testing.allocator, 2, pane_2) catch |err| {
        pane_2.deinit(testing.allocator);
        return err;
    };

    const expected_background: RGB = .{ .r = 10, .g = 11, .b = 12 };
    const expected_palette: RGB = .{ .r = 13, .g = 14, .b = 15 };
    {
        const t = &pane_1.terminal_owner.terminal;
        try t.printString("stale-one");
        try t.setTitle("pane title");
        try t.setPwd("file:///work");
        t.colors.background.set(expected_background);
        t.colors.palette.set(3, expected_palette);
        pane_1.stream.nextSlice("\x1b[31");
        t.screens.active.kitty_keyboard.push(.{
            .disambiguate = true,
            .report_events = false,
            .report_alternates = true,
            .report_all = true,
            .report_associated = true,
        });
    }
    try pane_2.terminal_owner.terminal.printString("stale-two");
    const expected_keyboard = pane_1.terminal_owner.terminal
        .screens.active.kitty_keyboard.current().int();

    const Accept = struct {
        expected_id: usize,

        pub fn submitPaneRefresh(
            self: @This(),
            members: []const []const u8,
        ) !void {
            try testing.expectEqual(5, members.len);
            var target: [32]u8 = undefined;
            const prefix = try std.fmt.bufPrint(
                &target,
                "display-message -p -t %{d} -F ",
                .{self.expected_id},
            );
            try testing.expect(std.mem.startsWith(u8, members[0], prefix));
            try testing.expect(std.mem.containsAtLeast(
                u8,
                members[0],
                1,
                "#{pane_width};#{pane_height}",
            ));
            try testing.expect(std.mem.startsWith(u8, members[1], "capture-pane -p -e -N -q -S -"));
            try testing.expect(std.mem.startsWith(u8, members[2], "capture-pane -p -e -N -a"));
            try testing.expect(std.mem.startsWith(u8, members[3], "capture-pane -p -e -N -q"));
            try testing.expect(std.mem.startsWith(u8, members[4], "capture-pane -p -P -C"));
        }
    };

    try viewer.refreshPane(1, Accept{ .expected_id = 1 });
    try viewer.refreshPane(2, Accept{ .expected_id = 2 });
    try testing.expectEqual(Viewer.Pane.Phase.refreshing, pane_1.phase);
    try testing.expectEqual(Viewer.Pane.Phase.refreshing, pane_2.phase);

    // A later global state query for newly discovered panes must not mutate
    // either already-refreshing terminal.
    _ = try viewer.receivedPaneState(
        null,
        "%1;5;1;0;0;1;block;;0;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;0;0;0;0;;0;one",
    );
    try testing.expectEqual(10, pane_1.terminal_owner.terminal.cols);
    try testing.expectEqual(11, pane_2.terminal_owner.terminal.cols);

    _ = try viewer.receivedPaneState(
        1,
        "%1;12;3;0;0;1;block;;0;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;0;0;0;2;8;0;one",
    );

    // The shown terminal changes only once the whole snapshot is in.
    try testing.expectEqual(10, pane_1.terminal_owner.terminal.cols);
    const kept_contents = try pane_1.terminal_owner.terminal.plainString(testing.allocator);
    defer testing.allocator.free(kept_contents);
    try testing.expectEqualStrings("stale-one", kept_contents);

    try testing.expect(try viewer.receivedPanePending(1, ""));
    try testing.expectEqual(12, pane_1.terminal_owner.terminal.cols);
    try testing.expectEqual(3, pane_1.terminal_owner.terminal.rows);
    try testing.expectEqual(11, pane_2.terminal_owner.terminal.cols);
    const refreshed_contents = try pane_1.terminal_owner.terminal.plainString(testing.allocator);
    defer testing.allocator.free(refreshed_contents);
    try testing.expectEqualStrings("", refreshed_contents);
    try testing.expectEqualStrings("pane title", pane_1.terminal_owner.terminal.getTitle().?);
    try testing.expectEqualStrings("file:///work", pane_1.terminal_owner.terminal.getPwd().?);
    try testing.expectEqual(expected_background, pane_1.terminal_owner.terminal.colors.background.get().?);
    try testing.expectEqual(expected_palette, pane_1.terminal_owner.terminal.colors.palette.current[3]);
    try testing.expectEqual(
        expected_keyboard,
        pane_1.terminal_owner.terminal.screens.active.kitty_keyboard.current().int(),
    );
    try testing.expect(pane_1.terminal_owner.terminal.tabstops.get(8));
    try testing.expect(!pane_1.terminal_owner.terminal.tabstops.get(7));
    pane_1.stream.nextSlice("mX");
    const parser_reset_contents = try pane_1.terminal_owner.terminal.plainString(testing.allocator);
    defer testing.allocator.free(parser_reset_contents);
    try testing.expectEqualStrings("mX", parser_reset_contents);

    _ = try viewer.receivedPaneState(
        2,
        "%2;14;4;0;0;1;block;;0;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;0;0;0;3;8;1;two",
    );
    try testing.expect(try viewer.receivedPanePending(2, ""));
    try testing.expectEqual(14, pane_2.terminal_owner.terminal.cols);
    try testing.expectEqual(4, pane_2.terminal_owner.terminal.rows);
}

fn testResizeWindow(id: usize, layout_str: []const u8, active: bool) !Viewer.Window {
    var arena = ArenaAllocator.init(testing.allocator);
    errdefer arena.deinit();
    const layout = try Layout.parseWithChecksum(arena.allocator(), layout_str);
    return .{
        .id = id,
        .name = "",
        .width = layout.width,
        .height = layout.height,
        .is_zoomed = false,
        .is_active = active,
        .active_pane_id = 0,
        .layout_arena = arena.state,
        .layout = layout,
        .visible_layout = layout,
    };
}

fn testResizePane(
    viewer: *Viewer,
    id: usize,
    rows: size.CellCountInt,
    bytes: []const u8,
) !*Viewer.Pane {
    const pane = try Viewer.Pane.init(testing.io, testing.allocator, .{
        .cols = 20,
        .rows = rows,
        .max_scrollback_bytes = 1_000_000,
    });
    pane.phase = .live;
    pane.layout_cols = 20;
    pane.layout_rows = rows;
    viewer.panes.put(testing.allocator, id, pane) catch |err| {
        pane.deinit(testing.allocator);
        return err;
    };
    pane.stream.nextSlice(bytes);
    return pane;
}

const TestAcceptResize = struct {
    pub fn submitClientResize(_: @This(), members: []const []const u8) !void {
        try testing.expectEqual(3, members.len);
        try testing.expect(std.mem.startsWith(u8, members[0], "list-panes -s -F '#{pane_id};"));
        try testing.expect(std.mem.startsWith(u8, members[1], "refresh-client -C "));
        try testing.expectEqualStrings(members[0], members[2]);
    }
};

fn testComplete(viewer: *Viewer, body: []const u8) []const Viewer.Action {
    return viewer.next(.{ .command_complete = .{ .success = body } });
}

fn testOutput(viewer: *Viewer, pane_id: usize, comptime data: []const u8) void {
    var buffer: [data.len]u8 = data[0..data.len].*;
    _ = viewer.next(.{ .tmux = .{ .output = .{ .pane_id = pane_id, .data = &buffer } } });
}

fn testCommandWith(actions: []const Viewer.Action, member: []const u8) ?Viewer.CommandGroup {
    for (actions) |action| switch (action) {
        .command => |group| for (group.members) |m| {
            if (std.mem.eql(u8, m, member)) return group;
        },
        else => {},
    };
    return null;
}

test "client resize applies tmux's row rules in place" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();
    viewer.state = .command_queue;
    viewer.tmux_version = try testing.allocator.dupe(u8, "3.5a");
    try viewer.windows.append(testing.allocator, try testResizeWindow(1, "9ede,20x10,0,0,1", true));
    const pane = try testResizePane(
        &viewer,
        1,
        10,
        "L0\r\nL1\r\nL2\r\nL3\r\nL4\x1b[7;1HF6\r\nF7\r\nF8\r\nF9\x1b[6;1H",
    );

    try viewer.setClientSize(.{ .columns = 20, .rows = 6 }, TestAcceptResize{});

    // A size asked for while the resize is in flight waits for its reply.
    try viewer.setClientSize(.{ .columns = 20, .rows = 10 }, TestAcceptResize{});
    try testing.expectEqual(Viewer.ClientSize{ .columns = 20, .rows = 10 }, viewer.resize_pending.?);

    _ = testComplete(&viewer, "%1;20;10;0;5;0;0;9ede,20x10,0,0,1;9ede,20x10,0,0,1");
    _ = testComplete(&viewer, "");
    const actions = testComplete(&viewer, "%1;20;6;0;5;0;0;f15e,20x6,0,0,1;f15e,20x6,0,0,1");

    // tmux deleted the four rows below the cursor and moved nothing into
    // history; the mirror matches.
    const t = &pane.terminal_owner.terminal;
    try testing.expectEqual(6, t.rows);
    try testing.expectEqual(0, resize.localHistory(t));
    const contents = try t.plainString(testing.allocator);
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("L0\nL1\nL2\nL3\nL4", contents);
    try testing.expect(!pane.stale);
    try testing.expectEqual(Viewer.Pane.Phase.live, pane.phase);

    // The pending size goes out with the reply's actions.
    try testing.expect(testCommandWith(actions, "refresh-client -C 20x10") != null);
    try testing.expect(viewer.resize_inflight != null);
    try testing.expect(viewer.resize_pending == null);
}

test "pane changes report the render holds a pane's output begins" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();
    viewer.state = .command_queue;
    const pane = try addTestPane(&viewer);
    pane.phase = .live;

    const steps = [_]struct { data: []const u8, held: bool, generation: u64 }{
        // The output leaves a hold on.
        .{ .data = "\\033[?2026hA", .held = true, .generation = 1 },
        // Setting the mode during a hold begins no new hold.
        .{ .data = "\\033[?2026hB", .held = true, .generation = 1 },
        .{ .data = "C\\033[?2026l", .held = false, .generation = 1 },
        // A whole frame within one output.
        .{ .data = "\\033[?2026hD\\033[?2026l", .held = false, .generation = 2 },
        // A frame ends and the next begins within one output: a new hold,
        // and the renderer never sees the pane released.
        .{ .data = "\\033[?2026hE\\033[?2026l\\033[?2026hF", .held = true, .generation = 4 },
    };
    for (steps) |step| {
        var buffer: [64]u8 = undefined;
        @memcpy(buffer[0..step.data.len], step.data);
        const actions = viewer.next(.{ .tmux = .{ .output = .{
            .pane_id = 1,
            .data = buffer[0..step.data.len],
        } } });
        try testing.expectEqual(1, actions.len);
        try testing.expectEqual(Viewer.PaneChange{
            .pane_id = 1,
            .render_hold = step.held,
            .render_hold_generation = step.generation,
        }, actions[0].pane_changed);
    }
}

test "ending a pane's render hold resets synchronized output" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();
    viewer.state = .command_queue;
    const pane = try addTestPane(&viewer);
    pane.phase = .live;
    testOutput(&viewer, 1, "\\033[?2026hA");
    try testing.expect(pane.terminal_owner.terminal.modes.get(.synchronized_output));

    pane.endRenderHold();
    try testing.expect(!pane.terminal_owner.terminal.modes.get(.synchronized_output));
    var more = "B".*;
    const actions = viewer.next(.{ .tmux = .{ .output = .{ .pane_id = 1, .data = &more } } });
    try testing.expectEqual(1, actions.len);
    try testing.expectEqual(Viewer.PaneChange{
        .pane_id = 1,
        .render_hold = false,
        .render_hold_generation = 1,
    }, actions[0].pane_changed);
}

test "a resize applied in place reports the render hold it ended" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();
    viewer.state = .command_queue;
    viewer.tmux_version = try testing.allocator.dupe(u8, "3.5a");
    try viewer.windows.append(testing.allocator, try testResizeWindow(1, "9ede,20x10,0,0,1", true));
    const pane = try testResizePane(
        &viewer,
        1,
        10,
        "L0\r\nL1\r\nL2\r\nL3\r\nL4\x1b[7;1HF6\r\nF7\r\nF8\r\nF9\x1b[6;1H\x1b[?2026h",
    );
    try testing.expect(pane.terminal_owner.terminal.modes.get(.synchronized_output));

    try viewer.setClientSize(.{ .columns = 20, .rows = 6 }, TestAcceptResize{});
    _ = testComplete(&viewer, "%1;20;10;0;5;0;0;9ede,20x10,0,0,1;9ede,20x10,0,0,1");
    _ = testComplete(&viewer, "");
    const actions = testComplete(&viewer, "%1;20;6;0;5;0;0;f15e,20x6,0,0,1;f15e,20x6,0,0,1");

    try testing.expect(!pane.stale);
    try testing.expectEqual(6, pane.terminal_owner.terminal.rows);
    const change = for (actions) |action| switch (action) {
        .pane_changed => |c| break c,
        else => {},
    } else return error.TestExpectedPaneChange;
    try testing.expectEqual(Viewer.PaneChange{
        .pane_id = 1,
        .render_hold = false,
        .render_hold_generation = 1,
    }, change);
}

test "a resize the mirror can't follow reports the render hold it ended" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();
    viewer.state = .command_queue;
    viewer.tmux_version = try testing.allocator.dupe(u8, "3.5a");
    try viewer.windows.append(testing.allocator, try testResizeWindow(1, "9ede,20x10,0,0,1", true));
    const pane = try testResizePane(&viewer, 1, 10, "L0\r\nL1\x1b[?2026h");

    // tmux's cursor before the resize isn't the mirror's.
    try viewer.setClientSize(.{ .columns = 20, .rows = 6 }, TestAcceptResize{});
    _ = testComplete(&viewer, "%1;20;10;7;7;0;0;9ede,20x10,0,0,1;9ede,20x10,0,0,1");
    _ = testComplete(&viewer, "");
    const actions = testComplete(&viewer, "%1;20;6;7;5;0;0;f15e,20x6,0,0,1;f15e,20x6,0,0,1");

    // The shown pane is recaptured at once.
    try testing.expect(testCommandWith(actions, "refresh-client -A '%1:pause'") != null);
    try testing.expectEqual(Viewer.Pane.Phase.refresh_pausing, pane.phase);
    try testing.expectEqual(6, pane.terminal_owner.terminal.rows);
    const change = for (actions) |action| switch (action) {
        .pane_changed => |c| break c,
        else => {},
    } else return error.TestExpectedPaneChange;
    try testing.expectEqual(Viewer.PaneChange{
        .pane_id = 1,
        .render_hold = false,
        .render_hold_generation = 1,
    }, change);
}

test "a recaptured pane's new stream keeps counting render holds" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();
    const pane = try testAlternateRecapture(&viewer);
    _ = testFinishAlternateRecapture(&viewer, "N0\nN1");
    _ = testComplete(&viewer, "");
    try testing.expectEqual(Viewer.Pane.Phase.live, pane.phase);
    const before = pane.render_hold_generation;

    var hold = "\\033[?2026hX".*;
    const actions = viewer.next(.{ .tmux = .{ .output = .{ .pane_id = 1, .data = &hold } } });
    try testing.expectEqual(1, actions.len);
    try testing.expect(actions[0].pane_changed.render_hold);
    try testing.expectEqual(before + 1, actions[0].pane_changed.render_hold_generation);
}

test "client resize keeps panes in place when tmux's layout notifications follow the reply" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();
    viewer.state = .command_queue;
    viewer.tmux_version = try testing.allocator.dupe(u8, "3.5a");
    try viewer.windows.append(testing.allocator, try testResizeWindow(1, "9ede,20x10,0,0,1", false));
    try viewer.windows.append(testing.allocator, try testResizeWindow(2, "9edf,20x10,0,0,2", true));
    const hidden = try testResizePane(&viewer, 1, 10, "a");
    const shown = try testResizePane(&viewer, 2, 10, "b");

    try viewer.setClientSize(.{ .columns = 20, .rows = 6 }, TestAcceptResize{});
    _ = testComplete(&viewer, "%1;20;10;1;0;0;0;9ede,20x10,0,0,1;9ede,20x10,0,0,1\n" ++
        "%2;20;10;1;0;0;0;9edf,20x10,0,0,2;9edf,20x10,0,0,2");
    _ = testComplete(&viewer, "");
    _ = testComplete(&viewer, "%1;20;6;1;0;0;0;f15e,20x6,0,0,1;f15e,20x6,0,0,1\n" ++
        "%2;20;6;1;0;0;0;f15f,20x6,0,0,2;f15f,20x6,0,0,2");

    // tmux's notification for each window arrives after the reply, the
    // shown window's last.
    const first = viewer.next(.{ .tmux = .{ .layout_change = .{
        .window_id = 1,
        .layout = "f15e,20x6,0,0,1",
        .visible_layout = "f15e,20x6,0,0,1",
        .raw_flags = "-",
    } } });
    for (first) |action| try testing.expect(action != .command);
    for ([_]*Viewer.Pane{ hidden, shown }) |pane| {
        try testing.expect(!pane.stale);
        try testing.expectEqual(6, pane.terminal_owner.terminal.rows);
    }
}

fn expectLayoutPanesTracked(viewer: *const Viewer, layout: Layout) !void {
    switch (layout.content) {
        .pane => |id| try testing.expect(viewer.panes.contains(id)),
        .horizontal, .vertical => |children| for (children) |child| {
            try expectLayoutPanesTracked(viewer, child);
        },
    }
}

test "client resize tracks a pane its samples show before its layout change" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();
    viewer.state = .command_queue;
    viewer.tmux_version = try testing.allocator.dupe(u8, "3.5a");
    try viewer.windows.append(testing.allocator, try testResizeWindow(0, "9edd,20x10,0,0,0", true));
    _ = try testResizePane(&viewer, 0, 10, "");

    // tmux 3.5a, `split-window -d` and the resize read in one write: tmux
    // runs both before notifying the split, so both samples already hold
    // the new pane %1 and its %layout-change follows the reply.
    try viewer.setClientSize(.{ .columns = 20, .rows = 6 }, TestAcceptResize{});
    _ = testComplete(&viewer, "%0;20;5;8;0;0;0;3962,20x10,0,0[20x5,0,0,0,20x4,0,6,1];\n" ++
        "%1;20;4;0;0;0;0;;");
    _ = testComplete(&viewer, "");
    const actions = testComplete(&viewer, "%0;20;3;8;0;0;0;77f5,20x6,0,0[20x3,0,0,0,20x2,0,4,1];\n" ++
        "%1;20;2;0;0;0;0;;");

    for (viewer.windows.items) |window| try expectLayoutPanesTracked(&viewer, window.layout);
    try testing.expectEqual(Viewer.Pane.Phase.initial_hydrating, viewer.panes.get(1).?.phase);
    try testing.expect(testCommandWith(actions, "capture-pane -p -P -C -t %1") != null);

    const notified = viewer.next(.{ .tmux = .{ .layout_change = .{
        .window_id = 0,
        .layout = "77f5,20x6,0,0[20x3,0,0,0,20x2,0,4,1]",
        .visible_layout = "77f5,20x6,0,0[20x3,0,0,0,20x2,0,4,1]",
        .raw_flags = "*",
    } } });
    try testing.expect(testCommandWith(notified, "capture-pane -p -P -C -t %1") == null);
}

test "client resize follows panes whose sample line has no layout" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();
    viewer.state = .command_queue;
    viewer.tmux_version = try testing.allocator.dupe(u8, "3.5a");
    try viewer.windows.append(testing.allocator, try testResizeWindow(
        1,
        "b972,20x10,0,0[20x5,0,0,1,20x4,0,6,2]",
        true,
    ));
    const top = try testResizePane(&viewer, 1, 5, "");
    const bottom = try testResizePane(&viewer, 2, 4, "");

    // tmux prints the window's layout once, on its top-left pane.
    try viewer.setClientSize(.{ .columns = 20, .rows = 6 }, TestAcceptResize{});
    _ = testComplete(&viewer, "%1;20;5;0;0;0;0;b972,20x10,0,0[20x5,0,0,1,20x4,0,6,2];\n" ++
        "%2;20;4;0;0;0;0;;");
    _ = testComplete(&viewer, "");
    const actions = testComplete(&viewer, "%1;20;3;0;0;0;0;f805,20x6,0,0[20x3,0,0,1,20x2,0,4,2];\n" ++
        "%2;20;2;0;0;0;0;;");

    for (actions) |action| try testing.expect(action != .command);
    try testing.expectEqual(3, top.terminal_owner.terminal.rows);
    try testing.expectEqual(2, bottom.terminal_owner.terminal.rows);
    try testing.expect(!top.stale and !bottom.stale);
    try testing.expectEqual(6, viewer.windows.items[0].height);
    try testing.expect(!viewer.windows.items[0].is_zoomed);
}

test "client resize recaptures panes whose output may have passed the reply" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();
    viewer.state = .command_queue;
    viewer.tmux_version = try testing.allocator.dupe(u8, "3.5a");
    try viewer.windows.append(testing.allocator, try testResizeWindow(1, "9ede,20x10,0,0,1", true));
    try viewer.windows.append(testing.allocator, try testResizeWindow(2, "9edf,20x10,0,0,2", false));
    const shown = try testResizePane(&viewer, 1, 10, "");
    const hidden = try testResizePane(&viewer, 2, 10, "");

    try viewer.setClientSize(.{ .columns = 20, .rows = 6 }, TestAcceptResize{});
    testOutput(&viewer, 1, "a");
    testOutput(&viewer, 2, "b");
    _ = testComplete(&viewer, "%1;20;10;1;0;0;0;9ede,20x10,0,0,1;9ede,20x10,0,0,1\n" ++
        "%2;20;10;1;0;0;0;9edf,20x10,0,0,2;9edf,20x10,0,0,2");
    _ = testComplete(&viewer, "");
    const actions = testComplete(&viewer, "%1;20;6;1;0;0;0;f15e,20x6,0,0,1;f15e,20x6,0,0,1\n" ++
        "%2;20;6;1;0;0;0;f15f,20x6,0,0,2;f15f,20x6,0,0,2");

    // Both panes printed during the resize, so either could be out of order.
    // The shown pane is recaptured now; the hidden one when it's shown.
    try testing.expect(testCommandWith(actions, "refresh-client -A '%1:pause'") != null);
    try testing.expectEqual(Viewer.Pane.Phase.refresh_pausing, shown.phase);
    try testing.expectEqual(Viewer.Pane.Phase.live, hidden.phase);
    try testing.expect(hidden.stale);
    try testing.expectEqual(6, hidden.terminal_owner.terminal.rows);

    const switched = viewer.next(.{ .tmux = .{ .session_window_changed = .{
        .session_id = viewer.session_id,
        .window_id = 2,
    } } });
    try testing.expect(testCommandWith(switched, "refresh-client -A '%2:pause'") != null);
    try testing.expectEqual(Viewer.Pane.Phase.refresh_pausing, hidden.phase);
}

test "paused recapture replays output that postdates the snapshot" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();
    viewer.state = .command_queue;
    viewer.tmux_version = try testing.allocator.dupe(u8, "3.5a");
    const pane = try testResizePane(&viewer, 1, 3, "stale");

    const AcceptPause = struct {
        pub fn submitPaneRefresh(_: @This(), members: []const []const u8) !void {
            try testing.expectEqual(1, members.len);
            try testing.expectEqualStrings("refresh-client -A '%1:pause'", members[0]);
        }
    };
    try viewer.refreshPane(1, AcceptPause{});
    try testing.expectEqual(Viewer.Pane.Phase.refresh_pausing, pane.phase);

    // Output before the pause took effect is in the snapshot.
    testOutput(&viewer, 1, "early");
    const paused = testComplete(&viewer, "");
    const group = testCommandWith(paused, "refresh-client -A '%1:continue'").?;
    try testing.expectEqual(6, group.members.len);
    try testing.expect(std.mem.startsWith(u8, group.members[0], "display-message -p -t %1 "));
    try testing.expectEqual(Viewer.Pane.Phase.refreshing, pane.phase);

    // Output after it postdates the snapshot, even if it arrives first.
    testOutput(&viewer, 1, "LATE");
    _ = testComplete(&viewer, "%1;20;3;4;0;1;block;;0;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;0;0;0;2;;zsh;/tmp");
    _ = testComplete(&viewer, "");
    _ = testComplete(&viewer, "");
    _ = testComplete(&viewer, "SNAP");

    // The shown terminal keeps its contents until the snapshot is whole.
    {
        const kept = try pane.terminal_owner.terminal.plainString(testing.allocator);
        defer testing.allocator.free(kept);
        try testing.expectEqualStrings("stale", kept);
    }

    _ = testComplete(&viewer, "");
    _ = testComplete(&viewer, "");

    try testing.expectEqual(Viewer.Pane.Phase.live, pane.phase);
    const contents = try pane.terminal_owner.terminal.plainString(testing.allocator);
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("SNAPLATE", contents);
}

const TestAcceptPause = struct {
    pub fn submitPaneRefresh(_: @This(), members: []const []const u8) !void {
        try testing.expectEqual(1, members.len);
        try testing.expectEqualStrings("refresh-client -A '%1:pause'", members[0]);
    }
};

const test_alternate_state =
    "%1;20;3;0;0;1;block;;0;1;0;0;0;1;0;0;0;0;0;0;0;0;0;0;0;0;2;;vim;/tmp";

/// Recapture pane 1 (3 rows) while its program is on the alternate screen,
/// up to the snapshot, and return the pane.
fn testAlternateRecapture(viewer: *Viewer) !*Viewer.Pane {
    viewer.state = .command_queue;
    viewer.tmux_version = try testing.allocator.dupe(u8, "3.5a");
    try viewer.windows.append(testing.allocator, try testResizeWindow(1, "9ede,20x10,0,0,1", true));
    const pane = try testResizePane(viewer, 1, 3, "stale");
    try viewer.refreshPane(1, TestAcceptPause{});
    _ = testComplete(viewer, "");
    return pane;
}

fn testFinishAlternateRecapture(viewer: *Viewer, saved: []const u8) []const Viewer.Action {
    _ = testComplete(viewer, test_alternate_state);
    _ = testComplete(viewer, "");
    _ = testComplete(viewer, saved);
    _ = testComplete(viewer, "ALT");
    return testComplete(viewer, "");
}

test "the normal screen tmux kept at another height is recaptured when the program leaves" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();
    const pane = try testAlternateRecapture(&viewer);
    _ = testFinishAlternateRecapture(&viewer, "N0\nN1");
    _ = testComplete(&viewer, "");
    try testing.expectEqual(Viewer.Pane.Phase.live, pane.phase);
    try testing.expect(pane.primary_stale);
    try testing.expect(!pane.stale);

    var leave = "\x1b[?1049l".*;
    const left = viewer.next(.{ .tmux = .{ .output = .{ .pane_id = 1, .data = &leave } } });
    try testing.expect(testCommandWith(left, "refresh-client -A '%1:pause'") != null);
    try testing.expect(!pane.primary_stale);
}

test "the normal screen tmux kept at the pane's size needs no recapture" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();
    const pane = try testAlternateRecapture(&viewer);
    _ = testFinishAlternateRecapture(&viewer, "N0\nN1\nN2");
    _ = testComplete(&viewer, "");
    try testing.expect(!pane.primary_stale);

    var leave = "\x1b[?1049l".*;
    const left = viewer.next(.{ .tmux = .{ .output = .{ .pane_id = 1, .data = &leave } } });
    for (left) |action| try testing.expect(action != .command);
    try testing.expect(!pane.stale);
    const contents = try pane.terminal_owner.terminal.plainString(testing.allocator);
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("N0\nN1\nN2", contents);
}

test "leaving the alternate screen in the replayed output recaptures at once" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();
    const pane = try testAlternateRecapture(&viewer);
    testOutput(&viewer, 1, "\x1b[?1049l");
    const pending = testFinishAlternateRecapture(&viewer, "N0\nN1");
    try testing.expect(testCommandWith(pending, "refresh-client -A '%1:pause'") != null);
    try testing.expect(!pane.primary_stale);
    try testing.expectEqual(Viewer.Pane.Phase.refresh_pausing, pane.phase);
}

test "pane state restores a cursor waiting to wrap" {
    var viewer = try Viewer.init(testing.io, testing.allocator, .{});
    defer viewer.deinit();
    viewer.state = .command_queue;
    const pane = try testResizePane(&viewer, 1, 3, "");

    const Accept = struct {
        pub fn submitPaneRefresh(_: @This(), _: []const []const u8) !void {}
    };
    try viewer.refreshPane(1, Accept{});
    _ = testComplete(&viewer, "%1;20;3;20;0;1;block;;0;0;4294967295;4294967295;0;1;0;0;0;0;0;0;0;0;0;0;0;0;2;;zsh;/tmp");
    _ = testComplete(&viewer, "");
    _ = testComplete(&viewer, "");
    _ = testComplete(&viewer, "XXXXXXXXXXXXXXXXXXXX\r\nZ");
    _ = testComplete(&viewer, "");

    testOutput(&viewer, 1, "Y");
    const contents = try pane.terminal_owner.terminal.plainString(testing.allocator);
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("XXXXXXXXXXXXXXXXXXXX\nY", contents);
}
