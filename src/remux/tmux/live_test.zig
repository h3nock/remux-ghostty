//! The tmux client against a real tmux. Each test is skipped unless the
//! environment names what it needs, starts its own tmux server on a private
//! socket, and kills it afterwards, also on failure.
//!
//! Both need:
//!
//! - REMUX_TMUX_LIVE_BIN: the tmux binary, or a program that takes tmux's
//!   arguments and runs one, in a container say.
//! - REMUX_TMUX_LIVE_DIR: a directory for the files the panes' programs
//!   write, at the same path for those programs as for the test.
//!
//! Resizes: after every client resize, each zoomed pane's mirror must equal
//! tmux's pane, fetched through the same control connection. A pane that
//! falls back to a recapture isn't a failure; a mirror that differs from
//! tmux is, and is reported. It also needs:
//!
//! - REMUX_TMUX_LIVE_GEN: the content generator, run in each pane as
//!   `python3 -I <gen> <mode> <seed> <donefile>`; it writes its content,
//!   creates the done file and idles.
//! - REMUX_TMUX_LIVE_REPORT: the path of the report it writes.
//!
//! Pastes: a paste and the Enter after it, written together, must reach the
//! pane and the panes tmux copies its input to as the paste and then the
//! Enter, and every command after them must get its own reply. It also
//! needs:
//!
//! - REMUX_TMUX_LIVE_PASTE_REPORT: the path of the report it writes, with
//!   the commands the client wrote and the bytes each pane's program read.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ControlClient = @import("client.zig").ControlClient;
const CommandToken = @import("channel.zig").CommandToken;
const resize = @import("resize.zig");
const Screen = @import("../../terminal/Screen.zig");
const formatter = @import("../../terminal/formatter.zig");

const modes = [_][]const u8{
    "plain", "styled", "bars", "midcursor", "cleared", "cleared3", "region", "alt", "tui", "limit",
};

/// Client heights after attaching at 50x41: the keyboard shows and hides,
/// and a few other sizes.
const heights = [_]u16{ 25, 41, 25, 41, 33, 41, 60, 41, 12, 25, 41 };

const Kind = enum { left_right, top_bottom, single };

const Live = struct {
    bin: []const u8,
    gen: []const u8,
    dir: []const u8,
    socket: []const u8,
    env: std.process.Environ.Map,
    report: std.Io.File,
    runs: usize = 0,
    mismatches: usize = 0,
    errors: usize = 0,

    /// REMUX_TMUX_LIVE_MODES, if set, picks the modes run, comma-separated,
    /// and REMUX_TMUX_LIVE_WINDOWS the window count.
    modes: ?[]const u8 = null,
    windows: ?usize = null,

    fn wants(self: *const Live, mode: []const u8) bool {
        const names = self.modes orelse return true;
        var it = std.mem.splitScalar(u8, names, ',');
        while (it.next()) |name| if (std.mem.eql(u8, name, mode)) return true;
        return false;
    }

    /// Run one session, reporting a run that couldn't finish.
    fn run(self: *Live, version: []const u8, kind: Kind, windows: usize, mode: []const u8, seed: u64) !Counts {
        if (self.windows) |only| if (only != windows) return .{};
        return liveRun(self, version, kind, windows, mode, seed) catch |err| {
            self.errors += 1;
            try self.print("ERROR {s} {s} windows={d} {s} seed={d}: {s}", .{
                version, @tagName(kind), windows, mode, seed, @errorName(err),
            });
            return .{};
        };
    }

    fn tmux(self: *Live, args: []const []const u8) !void {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(testing.allocator);
        try argv.appendSlice(testing.allocator, &.{ self.bin, "-L", self.socket, "-f", "/dev/null" });
        try argv.appendSlice(testing.allocator, args);
        const result = try std.process.run(testing.allocator, testing.io, .{
            .argv = argv.items,
            .environ_map = &self.env,
        });
        testing.allocator.free(result.stdout);
        testing.allocator.free(result.stderr);
    }

    fn print(self: *Live, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.allocPrint(testing.allocator, fmt ++ "\n", args);
        defer testing.allocator.free(text);
        try self.report.writeStreamingAll(testing.io, text);
    }
};

const Counts = struct {
    resizes: usize = 0,
    pane_steps: usize = 0,
    fast: usize = 0,
    fallback: usize = 0,
    captured: usize = 0,
    bytes: usize = 0,

    /// Panes that differ from tmux right after attaching, and pane-steps
    /// that differ after a resize, on a pane that already differed at
    /// attach or on one that didn't.
    attach_mismatches: usize = 0,
    inherited_mismatches: usize = 0,
    new_mismatches: usize = 0,
};

/// One attached control client and the panes it compares.
const Run = struct {
    live: *Live,
    child: std.process.Child,
    client: ControlClient,
    buffer: []u8,

    /// Zoomed in the first windows callback, as the app does at attach.
    zoom: []const usize,
    zoomed: bool = false,

    /// Host commands not yet answered.
    pending: usize = 0,
    failure: ?anyerror = null,
    exited: bool = false,
    received: usize = 0,

    /// Panes the client started recapturing, and panes whose screen a
    /// resize group captured, since the last reset.
    recaptured: std.AutoArrayHashMapUnmanaged(usize, void) = .empty,
    captured: std.AutoArrayHashMapUnmanaged(usize, void) = .empty,

    /// The comparison of one pane in flight, and the history rows asked for.
    pane: usize = 0,
    requested: usize = 0,
    state_token: ?CommandToken = null,
    capture_token: ?CommandToken = null,
    state: std.ArrayList(u8) = .empty,
    label: []const u8 = "",
    mismatched: bool = false,

    fn deinit(self: *Run) void {
        self.state.deinit(testing.allocator);
        self.recaptured.deinit(testing.allocator);
        self.captured.deinit(testing.allocator);
        self.client.deinit();
        testing.allocator.free(self.buffer);
    }

    pub fn controlClientAction(self: *Run, action: ControlClient.Action) void {
        self.handle(action) catch |err| {
            if (self.failure == null) self.failure = err;
        };
    }

    fn handle(self: *Run, action: ControlClient.Action) !void {
        switch (action) {
            .exit => self.exited = true,
            .windows => if (!self.zoomed) {
                self.zoomed = true;
                for (self.zoom) |id| try self.command("resize-pane -Z -t %{d}", .{id});
            },
            .command_complete => |completion| {
                self.pending -= 1;
                const body = switch (completion.result) {
                    .success => |body| body,
                    else => return error.TmuxCommandFailed,
                };
                if (completion.token == self.state_token) {
                    self.state.clearRetainingCapacity();
                    try self.state.appendSlice(testing.allocator, body);
                } else if (completion.token == self.capture_token) {
                    try self.compare(body);
                }
            },
            .pane_changed, .input_failed => {},
        }
    }

    fn command(self: *Run, comptime fmt: []const u8, args: anytype) !void {
        var buffer: [256]u8 = undefined;
        _ = try self.client.enqueueCommand(try std.fmt.bufPrint(&buffer, fmt, args));
        self.pending += 1;
    }

    /// Send what the client queued, noting the recaptures and the screens
    /// its resize groups capture.
    fn flush(self: *Run) !void {
        const out = self.client.outboundBytes();
        if (out.len == 0) return;
        var lines = std.mem.splitScalar(u8, out, '\n');
        while (lines.next()) |line| {
            const resize_group = std.mem.indexOf(u8, line, "refresh-client -C ") != null;
            var members = std.mem.splitSequence(u8, line, " ; ");
            while (members.next()) |member| {
                // A recapture: paused first from tmux 3.2, its state taken at
                // once on tmux 3.1.
                if (std.mem.startsWith(u8, member, "refresh-client -A '%") and
                    std.mem.endsWith(u8, member, ":pause'"))
                {
                    try self.recaptured.put(testing.allocator, paneId(member), {});
                } else if (std.mem.startsWith(u8, member, "display-message -p -t %") and
                    std.mem.indexOf(u8, member, " -F '") != null)
                {
                    try self.recaptured.put(testing.allocator, paneId(member), {});
                } else if (resize_group and std.mem.startsWith(u8, member, "capture-pane -p -e -N -q -t %") or
                    resize_group and std.mem.startsWith(u8, member, "capture-pane -p -N -q -t %"))
                {
                    try self.captured.put(testing.allocator, paneId(member), {});
                }
            }
        }
        try self.child.stdin.?.writeStreamingAll(testing.io, out);
        try self.client.consumeOutbound(out.len);
    }

    fn paneId(member: []const u8) usize {
        const start = std.mem.indexOfScalar(u8, member, '%').? + 1;
        var end = start;
        while (end < member.len and std.ascii.isDigit(member[end])) end += 1;
        return std.fmt.parseInt(usize, member[start..end], 10) catch unreachable;
    }

    /// Feed what tmux sends within `timeout_ms`. False if it sent nothing.
    fn pump(self: *Run, timeout_ms: i32) !bool {
        try self.flush();
        var fds = [_]std.posix.pollfd{.{
            .fd = self.child.stdout.?.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        if (try std.posix.poll(&fds, timeout_ms) == 0) return false;
        const len = try std.posix.read(fds[0].fd, self.buffer);
        if (len == 0) return error.TmuxClosed;
        self.received += len;
        try self.client.feed(self.buffer[0..len], self);
        if (self.failure) |err| return err;
        if (self.exited) return error.TmuxExited;
        try self.flush();
        return true;
    }

    /// Nothing in flight: every command answered and every pane live.
    fn idle(self: *Run) bool {
        const viewer = &self.client.viewer;
        if (self.pending != 0) return false;
        if (viewer.sent_command_count != 0 or !viewer.command_queue.empty()) return false;
        if (viewer.resize_inflight != null or viewer.resize_pending != null) return false;
        for (viewer.panes.values()) |pane| if (pane.phase != .live) return false;
        return self.client.outboundBytes().len == 0;
    }

    /// Wait until nothing is in flight and tmux has been quiet for a while,
    /// so its layout notifications and a program's repaint have arrived.
    fn settle(self: *Run) !void {
        for (0..2000) |_| {
            if (try self.pump(50)) continue;
            if (!self.idle()) continue;
            if (!try self.pump(250)) return;
        }
        return error.TmuxDidNotSettle;
    }

    /// Compare one pane's mirror with tmux's pane, fetched in one command
    /// line: its state, then every history row the mirror holds and the
    /// screen.
    fn check(self: *Run, pane_id: usize, label: []const u8) !void {
        const pane = self.client.viewer.panes.get(pane_id).?;
        const owner = pane.terminal_owner;
        const history = history: {
            owner.mutex.lockUncancelable(owner.terminal.io());
            defer owner.mutex.unlock(owner.terminal.io());
            break :history resize.localHistory(&owner.terminal);
        };

        var state_buffer: [160]u8 = undefined;
        var capture_buffer: [96]u8 = undefined;
        const members = [_][]const u8{
            try std.fmt.bufPrint(&state_buffer, "display-message -p -t %{d} " ++
                "'#{{pane_width}};#{{pane_height}};#{{cursor_x}};#{{cursor_y}};#{{history_size}};#{{alternate_on}}'", .{pane_id}),
            if (history == 0)
                try std.fmt.bufPrint(&capture_buffer, "capture-pane -p -N -q -S 0 -E - -t %{d}", .{pane_id})
            else
                try std.fmt.bufPrint(&capture_buffer, "capture-pane -p -N -q -S -{d} -E - -t %{d}", .{ history, pane_id }),
        };
        var tokens: [2]CommandToken = undefined;
        try self.client.enqueueCommandGroup(&members, &tokens);
        self.pending += 2;
        self.pane = pane_id;
        self.requested = history;
        self.state_token = tokens[0];
        self.capture_token = tokens[1];
        self.label = label;
        self.mismatched = false;
        for (0..2000) |_| {
            if (self.pending == 0) break;
            _ = try self.pump(50);
        } else return error.TmuxDidNotAnswer;
        self.state_token = null;
        self.capture_token = null;
    }

    /// Runs as tmux's capture arrives, before any later output reaches the
    /// mirror.
    fn compare(self: *Run, capture: []const u8) !void {
        var fields = std.mem.splitScalar(u8, std.mem.trim(u8, self.state.items, " \r\n"), ';');
        var values: [6]usize = undefined;
        for (&values) |*value| value.* = try std.fmt.parseInt(usize, fields.next() orelse return error.BadState, 10);
        const width, const height, const cursor_x, const cursor_y, const tmux_history, const alternate = values;

        // The control parser drops a reply's trailing newlines, so trailing
        // blank rows are missing from it.
        const captured_history = @min(self.requested, tmux_history);
        var lines: std.ArrayList([]const u8) = .empty;
        defer lines.deinit(testing.allocator);
        var it = std.mem.splitScalar(u8, capture, '\n');
        while (it.next()) |line| try lines.append(testing.allocator, std.mem.trimEnd(u8, line, " "));
        if (lines.items.len > captured_history + height) {
            return self.mismatch("capture has {d} rows for {d} history rows and a {d}-row screen", .{
                lines.items.len, captured_history, height,
            });
        }
        while (lines.items.len < captured_history + height) try lines.append(testing.allocator, "");

        const owner = self.client.viewer.panes.get(self.pane).?.terminal_owner;
        owner.mutex.lockUncancelable(owner.terminal.io());
        defer owner.mutex.unlock(owner.terminal.io());
        const t = &owner.terminal;
        const screen = t.screens.active;
        if (t.cols != width or t.rows != height) {
            return self.mismatch("mirror {d}x{d}, tmux {d}x{d}", .{ t.cols, t.rows, width, height });
        }
        if ((t.screens.active_key == .alternate) != (alternate == 1)) {
            return self.mismatch("alternate screen: tmux {d}", .{alternate});
        }

        var differing: usize = 0;
        for (0..height) |y| {
            const row = try rowText(screen, .{ .active = .{ .y = @intCast(y) } });
            defer testing.allocator.free(row);
            const expected = lines.items[captured_history + y];
            if (std.mem.eql(u8, row, expected)) continue;
            differing += 1;
            if (differing <= 3) try self.mismatch("screen row {d}: mirror '{s}' tmux '{s}'", .{ y, row, expected });
        }
        if (!resize.cursorMatches(t, cursor_x, cursor_y)) {
            try self.mismatch("cursor: mirror ({d},{d}) tmux ({d},{d})", .{
                screen.cursor.x, screen.cursor.y, cursor_x, cursor_y,
            });
        }
        if (alternate == 1) return;

        const mirror_history = resize.localHistory(t);
        if (mirror_history > tmux_history) {
            try self.mismatch("mirror holds {d} history rows, tmux {d}", .{ mirror_history, tmux_history });
        }
        const compared = @min(mirror_history, captured_history);
        differing = 0;
        for (0..compared) |j| {
            const y = mirror_history - compared + j;
            const row = try rowText(screen, .{ .history = .{ .y = @intCast(y) } });
            defer testing.allocator.free(row);
            const expected = lines.items[captured_history - compared + j];
            if (std.mem.eql(u8, row, expected)) continue;
            differing += 1;
            if (differing <= 3) try self.mismatch("history row {d} of {d} (tmux {d}, {d} captured, " ++
                "tmux's newest '{s}'): mirror '{s}' tmux '{s}'", .{
                y,   mirror_history, tmux_history, captured_history,
                lines.items[captured_history - 1], row, expected,
            });
        }
    }

    fn mismatch(self: *Run, comptime fmt: []const u8, args: anytype) !void {
        if (!self.mismatched) self.live.mismatches += 1;
        self.mismatched = true;
        try self.live.print("MISMATCH {s} pane %{d}: " ++ fmt, .{ self.label, self.pane } ++ args);
    }
};

/// One row's text, without trailing blanks.
fn rowText(screen: *const Screen, pt: @import("../../terminal/point.zig").Point) ![]u8 {
    const start = screen.pages.pin(pt).?;
    var end = start;
    end.x = screen.pages.cols - 1;
    var f: formatter.PageListFormatter = .init(&screen.pages, .plain);
    f.top_left = start;
    f.bottom_right = end;
    var builder: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer builder.deinit();
    try f.format(&builder.writer);
    const text = try builder.toOwnedSlice();
    const trimmed = std.mem.trimEnd(u8, text, " ");
    if (trimmed.len == text.len) return text;
    defer testing.allocator.free(text);
    return testing.allocator.dupe(u8, trimmed);
}

/// Start `windows` windows of `kind`, the generator in each one's first
/// pane, attach the client, then resize it through `heights`, comparing
/// every generator pane after each resize.
fn liveRun(live: *Live, version: []const u8, kind: Kind, windows: usize, mode: []const u8, seed: u64) !Counts {
    live.runs += 1;
    try live.tmux(&.{"kill-server"});
    defer live.tmux(&.{"kill-server"}) catch {};

    var done_paths: std.ArrayList([]u8) = .empty;
    defer {
        for (done_paths.items) |path| testing.allocator.free(path);
        done_paths.deinit(testing.allocator);
    }
    for (0..windows) |i| {
        const done = try std.fmt.allocPrint(testing.allocator, "{s}/live-{d}-{d}-{d}.done", .{
            live.dir, std.c.getpid(), live.runs, i,
        });
        try done_paths.append(testing.allocator, done);
        const gen = try std.fmt.allocPrint(testing.allocator, "python3 -I {s} {s} {d} {s}", .{ live.gen, mode, seed + i, done });
        defer testing.allocator.free(gen);
        var target_buffer: [16]u8 = undefined;
        const target = try std.fmt.bufPrint(&target_buffer, "s:{d}", .{i});
        if (i == 0) {
            try live.tmux(&.{ "new-session", "-d", "-s", "s", "-x", "50", "-y", "41", gen });
        } else {
            try live.tmux(&.{ "new-window", "-d", "-t", target, gen });
        }
        switch (kind) {
            .left_right => try live.tmux(&.{ "split-window", "-d", "-h", "-t", target, "sleep 100000" }),
            .top_bottom => try live.tmux(&.{ "split-window", "-d", "-v", "-t", target, "sleep 100000" }),
            .single => {},
        }
    }
    for (done_paths.items) |done| {
        for (0..400) |_| {
            if (std.Io.Dir.accessAbsolute(testing.io, done, .{})) |_| break else |_| {}
            var none: [0]std.posix.pollfd = .{};
            _ = try std.posix.poll(&none, 25);
        } else return error.GeneratorDidNotFinish;
    }

    // The generator panes, which the app zooms at attach.
    var panes: [8]usize = undefined;
    for (0..windows) |i| panes[i] = if (kind == .single) i else 2 * i;
    const generators = panes[0..windows];

    var run: Run = .{
        .live = live,
        .child = try std.process.spawn(testing.io, .{
            .argv = &.{ live.bin, "-L", live.socket, "-f", "/dev/null", "-C", "attach", "-t", "s" },
            .environ_map = &live.env,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        }),
        .client = undefined,
        .buffer = undefined,
        .zoom = if (kind == .single) &.{} else generators,
    };
    defer run.child.kill(testing.io);
    run.buffer = try testing.allocator.alloc(u8, 1 << 16);
    run.client = ControlClient.init(testing.io, testing.allocator, .{
        .max_scrollback = 10_000,
        .history_line_limit = 2_000,
        .initial_client_size = .{ .columns = 50, .rows = 41 },
    }) catch |err| {
        testing.allocator.free(run.buffer);
        return err;
    };
    defer run.deinit();

    var label_buffer: [128]u8 = undefined;
    const name = try std.fmt.bufPrint(&label_buffer, "{s} {s} windows={d} {s} seed={d}", .{
        version, @tagName(kind), windows, mode, seed,
    });

    // Attach, every split window zoomed in one batch with the hydration.
    try run.settle();
    var stale_at_attach: usize = 0;
    for (run.client.viewer.panes.values()) |pane| stale_at_attach += @intFromBool(pane.stale);
    const recaptured_at_attach = run.recaptured.count();
    run.recaptured.clearRetainingCapacity();
    for (0..windows) |i| {
        try run.command("select-window -t s:{d}", .{i});
        try run.settle();
    }
    if (windows > 1) {
        try run.command("select-window -t s:0", .{});
        try run.settle();
    }
    const recaptured_on_select = run.recaptured.count();
    var counts: Counts = .{};
    var differed_at_attach: std.AutoArrayHashMapUnmanaged(usize, void) = .empty;
    defer differed_at_attach.deinit(testing.allocator);
    for (generators) |id| {
        try run.check(id, name);
        if (!run.mismatched) continue;
        counts.attach_mismatches += 1;
        try differed_at_attach.put(testing.allocator, id, {});
    }

    for (heights, 0..) |rows, step| {
        run.recaptured.clearRetainingCapacity();
        run.captured.clearRetainingCapacity();
        run.received = 0;
        try run.client.setClientSize(.{ .columns = 50, .rows = rows });
        try run.settle();
        counts.resizes += 1;
        counts.bytes += run.received;

        for (generators) |id| {
            counts.pane_steps += 1;
            counts.captured += @intFromBool(run.captured.contains(id));
            const pane = run.client.viewer.panes.get(id).?;
            if (run.recaptured.contains(id) or pane.stale) {
                counts.fallback += 1;
                // A hidden window's stale pane is recaptured when it's
                // shown; recapture it now to keep comparing it.
                if (pane.stale) {
                    try run.client.refreshPane(id);
                    try run.settle();
                }
            } else counts.fast += 1;
        }

        var step_label_buffer: [160]u8 = undefined;
        const step_label = try std.fmt.bufPrint(&step_label_buffer, "{s} step={d} rows={d}", .{ name, step, rows });
        for (generators) |id| {
            try run.check(id, step_label);
            if (!run.mismatched) continue;
            if (differed_at_attach.contains(id)) {
                counts.inherited_mismatches += 1;
            } else counts.new_mismatches += 1;
        }
    }

    try live.print("{s}: attach stale={d} recaptured={d} select recaptured={d} differing={d}; resizes={d} " ++
        "pane-steps={d} fast={d} fallback={d} captured={d} differing inherited={d} new={d} bytes/resize={d}", .{
        name,                   stale_at_attach,           recaptured_at_attach, recaptured_on_select,
        counts.attach_mismatches, counts.resizes,          counts.pane_steps,    counts.fast,
        counts.fallback,        counts.captured,           counts.inherited_mismatches, counts.new_mismatches,
        counts.bytes / counts.resizes,
    });
    return counts;
}

fn env(name: [*:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.span(value);
}

test "tmux client mirrors equal a real tmux across client resizes" {
    const bin = env("REMUX_TMUX_LIVE_BIN") orelse return error.SkipZigTest;
    const gen = env("REMUX_TMUX_LIVE_GEN") orelse return error.SkipZigTest;
    const dir = env("REMUX_TMUX_LIVE_DIR") orelse return error.SkipZigTest;
    const report_path = env("REMUX_TMUX_LIVE_REPORT") orelse return error.SkipZigTest;

    var socket_buffer: [64]u8 = undefined;
    var live: Live = .{
        .bin = bin,
        .gen = gen,
        .dir = dir,
        .socket = try std.fmt.bufPrint(&socket_buffer, "remux-forkfix-live-{d}", .{std.c.getpid()}),
        .env = .init(testing.allocator),
        .report = try std.Io.Dir.createFileAbsolute(testing.io, report_path, .{}),
        .modes = env("REMUX_TMUX_LIVE_MODES"),
        .windows = if (env("REMUX_TMUX_LIVE_WINDOWS")) |text| try std.fmt.parseInt(usize, text, 10) else null,
    };
    defer live.env.deinit();
    defer live.report.close(testing.io);
    try live.env.put("PATH", "/usr/bin:/bin");
    try live.env.put("HOME", env("HOME") orelse "/");
    try live.env.put("TERM", "xterm-256color");
    try live.env.put("LANG", "en_US.UTF-8");
    try live.env.put("SHELL", "/bin/sh");

    const version_result = try std.process.run(testing.allocator, testing.io, .{ .argv = &.{ bin, "-V" } });
    defer testing.allocator.free(version_result.stdout);
    defer testing.allocator.free(version_result.stderr);
    const version = std.mem.trim(u8, version_result.stdout, " \r\n");
    try live.print("== {s}", .{version});

    const seeds = [_]u64{ 11, 2024, 90001 };
    var totals = [_]Counts{.{}} ** 3;
    for (modes) |mode| {
        if (!live.wants(mode)) continue;
        for (seeds) |seed| add(&totals[0], try live.run(version, .left_right, 1, mode, seed));
        add(&totals[1], try live.run(version, .top_bottom, 1, mode, seeds[0]));
        add(&totals[2], try live.run(version, .single, 1, mode, seeds[0]));
        add(&totals[0], try live.run(version, .left_right, 3, mode, seeds[1]));
    }

    // Bytes per resize for 1, 3 and 6 zoomed left/right windows, the same
    // content in each.
    if (live.wants("plain")) for ([_]usize{ 1, 3, 6 }) |windows| {
        _ = try live.run(version, .left_right, windows, "plain", seeds[2]);
    };

    for (totals, [_][]const u8{ "left/right", "top/bottom", "single" }) |counts, name| {
        try live.print("TOTAL {s} {s}: resizes={d} pane-steps={d} fast={d} fallback={d} captured={d} " ++
            "differing at attach={d} after a resize inherited={d} new={d}", .{
            version,       name,            counts.resizes,           counts.pane_steps,
            counts.fast,   counts.fallback, counts.captured,          counts.attach_mismatches,
            counts.inherited_mismatches, counts.new_mismatches,
        });
    }
    try live.print("mismatches={d} errors={d}", .{ live.mismatches, live.errors });
    try testing.expectEqual(0, live.mismatches);
    try testing.expectEqual(0, live.errors);
}

fn add(total: *Counts, counts: Counts) void {
    inline for (@typeInfo(Counts).@"struct".fields) |field| {
        @field(total, field.name) += @field(counts, field.name);
    }
}

/// One attached control client that pastes.
const PasteRun = struct {
    live: *Live,
    child: std.process.Child,
    client: ControlClient,
    buffer: []u8,
    completions: std.ArrayList(Completion) = .empty,
    failure: ?anyerror = null,
    exited: bool = false,

    const Completion = struct {
        token: CommandToken,
        ok: bool,
        body: []u8,
    };

    fn deinit(self: *PasteRun) void {
        for (self.completions.items) |item| testing.allocator.free(item.body);
        self.completions.deinit(testing.allocator);
        self.client.deinit();
        testing.allocator.free(self.buffer);
    }

    pub fn controlClientAction(self: *PasteRun, action: ControlClient.Action) void {
        self.handle(action) catch |err| {
            if (self.failure == null) self.failure = err;
        };
    }

    fn handle(self: *PasteRun, action: ControlClient.Action) !void {
        switch (action) {
            .exit => self.exited = true,
            .command_complete => |complete| {
                const body = switch (complete.result) {
                    .success, .error_block => |body| body,
                    .skipped_after_error => "",
                };
                const copy = try testing.allocator.dupe(u8, body);
                errdefer testing.allocator.free(copy);
                try self.completions.append(testing.allocator, .{
                    .token = complete.token,
                    .ok = complete.result == .success,
                    .body = copy,
                });
            },
            .windows, .pane_changed, .input_failed => {},
        }
    }

    /// Write everything the client queued in one write.
    fn flush(self: *PasteRun) !void {
        const out = self.client.outboundBytes();
        if (out.len == 0) return;
        try self.child.stdin.?.writeStreamingAll(testing.io, out);
        try self.client.consumeOutbound(out.len);
    }

    /// Feed what tmux sends within `timeout_ms`. False if it sent nothing.
    fn pump(self: *PasteRun, timeout_ms: i32) !bool {
        try self.flush();
        var fds = [_]std.posix.pollfd{.{
            .fd = self.child.stdout.?.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        if (try std.posix.poll(&fds, timeout_ms) == 0) return false;
        const len = try std.posix.read(fds[0].fd, self.buffer);
        if (len == 0) return error.TmuxClosed;
        try self.client.feed(self.buffer[0..len], self);
        if (self.failure) |err| return err;
        if (self.exited) return error.TmuxExited;
        try self.flush();
        return true;
    }

    /// Wait until every pane is live, nothing is unanswered and tmux has
    /// been quiet for a while.
    fn settle(self: *PasteRun) !void {
        for (0..2000) |_| {
            if (try self.pump(50)) continue;
            if (self.client.channel.pending.len() != 0) continue;
            for (self.client.viewer.panes.values()) |pane| {
                if (pane.phase != .live) break;
            } else if (!try self.pump(250)) return;
        }
        return error.TmuxDidNotSettle;
    }

    /// Wait for the reply to `token`.
    fn completion(self: *PasteRun, token: CommandToken) !Completion {
        for (0..400) |_| {
            for (self.completions.items) |item| {
                if (item.token == token) return item;
            }
            _ = try self.pump(50);
        }
        return error.TmuxDidNotAnswer;
    }
};

/// What a paste scenario sets up in the session, whose first window has
/// panes 0, 1 and 2 and whose second has pane 3, and what it expects of a
/// paste of each text into pane 0 with Enter after each.
const PasteCase = struct {
    name: []const u8,
    texts: []const []const u8 = &.{"one\ntwo"},

    /// synchronize-panes on in the first window.
    synchronized: bool = true,

    /// A pane in copy mode, a pane whose program doesn't ask for bracketed
    /// pastes, and whether pane 0 is zoomed.
    copy_mode: ?usize = null,
    plain: ?usize = null,
    zoomed: bool = false,

    /// Close pane 0 just before the paste, so that the client still has it.
    target_gone: bool = false,

    /// What each pane's program reads.
    expected: [4][]const u8,
};

const pasted_one_two = "\x1b[200~one\rtwo\x1b[201~";

const paste_cases = [_]PasteCase{
    .{
        .name = "synchronized, one pane in copy mode",
        .copy_mode = 2,
        .expected = .{ pasted_one_two ++ "\r", pasted_one_two ++ "\r", "", "" },
    },
    .{
        .name = "not synchronized",
        .synchronized = false,
        .expected = .{ pasted_one_two ++ "\r", "", "", "" },
    },
    .{
        .name = "the pasted pane in copy mode",
        .synchronized = false,
        .copy_mode = 0,
        .expected = .{ pasted_one_two ++ "\r", "", "", "" },
    },
    .{
        .name = "synchronized, two pastes queued together",
        .texts = &.{ "one\ntwo", "three" },
        .expected = .{
            pasted_one_two ++ "\r\x1b[200~three\x1b[201~\r",
            pasted_one_two ++ "\r\x1b[200~three\x1b[201~\r",
            pasted_one_two ++ "\r\x1b[200~three\x1b[201~\r",
            "",
        },
    },
    .{
        .name = "synchronized, one pane without bracketed paste",
        .plain = 1,
        .expected = .{ pasted_one_two ++ "\r", "one\rtwo\r", pasted_one_two ++ "\r", "" },
    },
    .{
        .name = "synchronized, the pasted pane zoomed",
        .zoomed = true,
        .expected = .{ pasted_one_two ++ "\r", "", "", "" },
    },
    .{
        .name = "synchronized, the pasted pane gone",
        .target_gone = true,
        .expected = .{ "", "", "", "" },
    },
};

/// Bytes with the controls among them spelled out.
fn escaped(bytes: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    for (bytes) |byte| switch (byte) {
        '\r' => try out.writer.writeAll("\\r"),
        '\n' => try out.writer.writeAll("\\n"),
        0x1b => try out.writer.writeAll("\\e"),
        0x20...0x7e => try out.writer.writeByte(byte),
        else => try out.writer.print("\\x{x:0>2}", .{byte}),
    };
    return out.toOwnedSlice();
}

fn sleepMs(ms: i32) !void {
    var none: [0]std.posix.pollfd = .{};
    _ = try std.posix.poll(&none, ms);
}

/// Run one paste scenario. Returns whether everything was as expected.
fn pasteRun(live: *Live, version: []const u8, case: PasteCase) !bool {
    live.runs += 1;
    try live.tmux(&.{"kill-server"});
    defer live.tmux(&.{"kill-server"}) catch {};

    // Each pane's program asks for bracketed pastes, unless it is the
    // plain one, and writes every byte it reads to its log.
    var logs: [4][]u8 = undefined;
    var started: usize = 0;
    defer for (logs[0..started]) |log| {
        std.Io.Dir.deleteFileAbsolute(testing.io, log) catch {};
        testing.allocator.free(log);
    };
    for (0..4) |i| {
        logs[i] = try std.fmt.allocPrint(testing.allocator, "{s}/paste-{d}-{d}-{d}.log", .{
            live.dir, std.c.getpid(), live.runs, i,
        });
        started += 1;
        const program = try std.fmt.allocPrint(testing.allocator, "{s}stty raw -echo; exec cat > {s}", .{
            if (case.plain == i) "" else "printf '\\033[?2004h'; ",
            logs[i],
        });
        defer testing.allocator.free(program);
        switch (i) {
            0 => try live.tmux(&.{ "new-session", "-d", "-s", "s", "-x", "120", "-y", "40", program }),
            1, 2 => try live.tmux(&.{ "split-window", "-d", "-t", "s:0", program }),
            else => try live.tmux(&.{ "new-window", "-d", "-t", "s:1", program }),
        }
    }
    for (logs) |log| {
        for (0..400) |_| {
            if (std.Io.Dir.accessAbsolute(testing.io, log, .{})) |_| break else |_| {}
            try sleepMs(25);
        } else return error.PaneProgramDidNotStart;
    }
    try sleepMs(300);
    if (case.synchronized) try live.tmux(&.{ "set-option", "-w", "-t", "s:0", "synchronize-panes", "on" });
    if (case.zoomed) try live.tmux(&.{ "resize-pane", "-Z", "-t", "%0" });
    if (case.copy_mode) |pane| {
        var target_buffer: [16]u8 = undefined;
        try live.tmux(&.{ "copy-mode", "-t", try std.fmt.bufPrint(&target_buffer, "%{d}", .{pane}) });
    }

    var run: PasteRun = .{
        .live = live,
        .child = try std.process.spawn(testing.io, .{
            .argv = &.{ live.bin, "-L", live.socket, "-f", "/dev/null", "-C", "attach", "-t", "s" },
            .environ_map = &live.env,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        }),
        .client = undefined,
        .buffer = undefined,
    };
    defer run.child.kill(testing.io);
    run.buffer = try testing.allocator.alloc(u8, 1 << 16);
    run.client = ControlClient.init(testing.io, testing.allocator, .{}) catch |err| {
        testing.allocator.free(run.buffer);
        return err;
    };
    defer run.deinit();
    try run.settle();

    // The client doesn't hear that the pane closed before it pastes.
    if (case.target_gone) try live.tmux(&.{ "kill-pane", "-t", "%0" });

    // Every paste, the Enter after each, and three commands whose replies
    // show that each command still gets its own, all in one write.
    var pastes: [2]CommandToken = undefined;
    var enters: [2]CommandToken = undefined;
    for (case.texts, 0..) |text, i| {
        pastes[i] = try run.client.pastePane(0, text);
        enters[i] = try run.client.sendPaneInputTracked(0, "\r");
    }
    const buffers_token = try run.client.enqueueCommand("list-buffers -F '#{buffer_name}'");
    const mode_token = try run.client.enqueueCommand("display-message -p -t %0 'in a mode: #{pane_in_mode}'");
    const last_token = try run.client.enqueueCommand("display-message -p 'the last reply'");
    const written = try testing.allocator.dupe(u8, run.client.outboundBytes());
    defer testing.allocator.free(written);
    try run.flush();

    var ok = true;
    try live.print("== {s}: {s}", .{ version, case.name });
    try live.print("wrote in one write:\n{s}", .{std.mem.trimEnd(u8, written, "\n")});
    for (case.texts, 0..) |_, i| {
        const pasted = try run.completion(pastes[i]);
        const entered = try run.completion(enters[i]);
        try live.print("paste {d}: {s} {s}; Enter: {s} {s}", .{
            i,                                   if (pasted.ok) "ok" else "refused", pasted.body,
            if (entered.ok) "ok" else "refused", entered.body,
        });
        if (pasted.ok == case.target_gone or entered.ok == case.target_gone) ok = false;
    }

    // tmux has deleted the buffer and the pane is in no mode, and each of
    // these replies is its command's own: none was counted as another's.
    const buffers = try run.completion(buffers_token);
    const mode = try run.completion(mode_token);
    const last = try run.completion(last_token);
    try live.print("buffers left: '{s}'; pane %0 {s}; last reply: {s}", .{ buffers.body, mode.body, last.body });
    if (!buffers.ok or buffers.body.len != 0) ok = false;
    if (!case.target_gone and !(mode.ok and std.mem.eql(u8, mode.body, "in a mode: 0"))) ok = false;
    if (!last.ok or !std.mem.eql(u8, last.body, "the last reply")) ok = false;

    // Nor is any reply still awaited once tmux has gone quiet.
    try run.settle();

    // What each program read: give the bytes time to arrive, then a little
    // more for any that shouldn't.
    for (0..80) |_| {
        var complete = true;
        for (logs, case.expected) |log, expected| {
            const got = try std.Io.Dir.cwd().readFileAlloc(testing.io, log, testing.allocator, .limited(1 << 20));
            defer testing.allocator.free(got);
            if (got.len < expected.len) complete = false;
        }
        if (complete) break;
        try sleepMs(25);
    }
    try sleepMs(300);
    for (logs, case.expected, 0..) |log, expected, i| {
        const got = try std.Io.Dir.cwd().readFileAlloc(testing.io, log, testing.allocator, .limited(1 << 20));
        defer testing.allocator.free(got);
        const got_text = try escaped(got);
        defer testing.allocator.free(got_text);
        if (std.mem.eql(u8, got, expected)) {
            try live.print("pane %{d} read: {s}", .{ i, got_text });
            continue;
        }
        ok = false;
        const expected_text = try escaped(expected);
        defer testing.allocator.free(expected_text);
        try live.print("pane %{d} read: {s}   <-- expected {s}", .{ i, got_text, expected_text });
    }
    try live.print("{s}", .{if (ok) "PASS" else "FAIL"});
    if (!ok) live.mismatches += 1;
    return ok;
}

test "tmux client pastes reach a real tmux's panes ahead of the input after them" {
    const bin = env("REMUX_TMUX_LIVE_BIN") orelse return error.SkipZigTest;
    const dir = env("REMUX_TMUX_LIVE_DIR") orelse return error.SkipZigTest;
    const report_path = env("REMUX_TMUX_LIVE_PASTE_REPORT") orelse return error.SkipZigTest;

    var socket_buffer: [64]u8 = undefined;
    var live: Live = .{
        .bin = bin,
        .gen = "",
        .dir = dir,
        .socket = try std.fmt.bufPrint(&socket_buffer, "remux-paste-live-{d}", .{std.c.getpid()}),
        .env = .init(testing.allocator),
        .report = try std.Io.Dir.createFileAbsolute(testing.io, report_path, .{}),
    };
    defer live.env.deinit();
    defer live.report.close(testing.io);
    try live.env.put("PATH", "/usr/bin:/bin");
    try live.env.put("HOME", env("HOME") orelse "/");
    try live.env.put("TERM", "xterm-256color");
    try live.env.put("LANG", "en_US.UTF-8");
    try live.env.put("SHELL", "/bin/sh");

    const version_result = try std.process.run(testing.allocator, testing.io, .{ .argv = &.{ bin, "-V" } });
    defer testing.allocator.free(version_result.stdout);
    defer testing.allocator.free(version_result.stderr);
    const version = std.mem.trim(u8, version_result.stdout, " \r\n");

    for (paste_cases) |case| {
        _ = pasteRun(&live, version, case) catch |err| {
            live.errors += 1;
            try live.print("ERROR {s} {s}: {s}", .{ version, case.name, @errorName(err) });
        };
    }
    try live.print("mismatches={d} errors={d}", .{ live.mismatches, live.errors });
    try testing.expectEqual(0, live.mismatches);
    try testing.expectEqual(0, live.errors);
}
