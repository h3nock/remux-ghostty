//! Generic libghostty C boundary for producing terminal state without a PTY.
//!
//! A producer owns one shared terminal and one persistent VT stream. It is a
//! writer/lifetime boundary only: rendering and transport remain host concerns.

const std = @import("std");
const state = &@import("../global.zig").state;
const SharedTerminal = @import("Shared.zig");
const TerminalStream = @import("stream_terminal.zig").Stream;

pub const Result = enum(c_int) {
    ok,
    invalid_input,
    out_of_memory,
};

pub const Config = extern struct {
    columns: u16 = 80,
    rows: u16 = 24,
    max_scrollback: usize = 10_000,
};

pub const Producer = struct {
    alloc: std.mem.Allocator,
    terminal: *SharedTerminal,
    stream: TerminalStream,

    fn init(
        alloc: std.mem.Allocator,
        config: Config,
    ) std.mem.Allocator.Error!*Producer {
        const self = try alloc.create(Producer);
        errdefer alloc.destroy(self);

        const terminal = try SharedTerminal.init(alloc, .{
            .cols = config.columns,
            .rows = config.rows,
            .max_scrollback = config.max_scrollback,
        });
        errdefer terminal.release();

        self.* = .{
            .alloc = alloc,
            .terminal = terminal,
            .stream = terminal.terminal.vtStream(),
        };
        return self;
    }

    fn deinit(self: *Producer) void {
        const alloc = self.alloc;
        self.stream.deinit();
        self.terminal.release();
        alloc.destroy(self);
    }

    fn feed(self: *Producer, bytes: []const u8) void {
        self.terminal.mutex.lock();
        defer self.terminal.mutex.unlock();
        self.stream.nextSlice(bytes);
    }
};

pub export fn ghostty_terminal_producer_config_new() Config {
    return .{};
}

pub export fn ghostty_terminal_producer_new(
    config_ptr: ?*const Config,
    out_ptr: ?*?*Producer,
) Result {
    const out = out_ptr orelse return .invalid_input;
    out.* = null;
    const config = config_ptr orelse return .invalid_input;
    if (config.columns == 0 or config.rows == 0) return .invalid_input;

    out.* = Producer.init(state.alloc, config.*) catch return .out_of_memory;
    return .ok;
}

pub export fn ghostty_terminal_producer_retain_terminal(
    producer: ?*Producer,
    out_ptr: ?*?*SharedTerminal,
) Result {
    const out = out_ptr orelse return .invalid_input;
    out.* = null;
    const value = producer orelse return .invalid_input;
    out.* = value.terminal.retain();
    return .ok;
}

pub export fn ghostty_terminal_producer_feed(
    producer: ?*Producer,
    data_ptr: ?[*]const u8,
    len: usize,
) Result {
    const value = producer orelse return .invalid_input;
    const bytes: []const u8 = if (len == 0)
        &.{}
    else
        (data_ptr orelse return .invalid_input)[0..len];
    value.feed(bytes);
    return .ok;
}

pub export fn ghostty_terminal_producer_free(producer: ?*Producer) void {
    if (producer) |value| value.deinit();
}

pub export fn ghostty_terminal_release(terminal: ?*SharedTerminal) void {
    if (terminal) |value| value.release();
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

test "terminal producer C ABI matches ghostty header" {
    const testing = std.testing;
    const c = @import("ghostty.h");

    try testing.expect(@hasDecl(c, "ghostty_terminal_producer_config_new"));
    try testing.expect(@hasDecl(c, "ghostty_terminal_producer_new"));
    try testing.expect(@hasDecl(c, "ghostty_terminal_producer_retain_terminal"));
    try testing.expect(@hasDecl(c, "ghostty_terminal_producer_feed"));
    try testing.expect(@hasDecl(c, "ghostty_terminal_producer_free"));
    try testing.expect(@hasDecl(c, "ghostty_terminal_release"));
    try testing.expectEqual(
        @sizeOf(c_int),
        @sizeOf(c.ghostty_terminal_producer_result_e),
    );
    try testing.expectEqual(
        @as(c_int, @intFromEnum(Result.ok)),
        @as(c_int, c.GHOSTTY_TERMINAL_PRODUCER_RESULT_OK),
    );
    try testing.expectEqual(
        @as(c_int, @intFromEnum(Result.invalid_input)),
        @as(c_int, c.GHOSTTY_TERMINAL_PRODUCER_RESULT_INVALID_INPUT),
    );
    try testing.expectEqual(
        @as(c_int, @intFromEnum(Result.out_of_memory)),
        @as(c_int, c.GHOSTTY_TERMINAL_PRODUCER_RESULT_OUT_OF_MEMORY),
    );
    try expectStructLayout(Config, c.ghostty_terminal_producer_config_s);
}

test "terminal producer C defaults and validation" {
    const testing = std.testing;
    state.alloc = testing.allocator;

    const defaults = ghostty_terminal_producer_config_new();
    try testing.expectEqual(@as(u16, 80), defaults.columns);
    try testing.expectEqual(@as(u16, 24), defaults.rows);
    try testing.expectEqual(@as(usize, 10_000), defaults.max_scrollback);

    var out: ?*Producer = undefined;
    try testing.expectEqual(
        Result.invalid_input,
        ghostty_terminal_producer_new(null, &out),
    );
    try testing.expect(out == null);
    try testing.expectEqual(
        Result.invalid_input,
        ghostty_terminal_producer_new(&defaults, null),
    );

    var invalid = defaults;
    invalid.columns = 0;
    try testing.expectEqual(
        Result.invalid_input,
        ghostty_terminal_producer_new(&invalid, &out),
    );
    try testing.expect(out == null);
    invalid.columns = defaults.columns;
    invalid.rows = 0;
    try testing.expectEqual(
        Result.invalid_input,
        ghostty_terminal_producer_new(&invalid, &out),
    );
    try testing.expect(out == null);

    try testing.expectEqual(Result.ok, ghostty_terminal_producer_new(&defaults, &out));
    const producer = out.?;
    defer ghostty_terminal_producer_free(producer);

    var retained: ?*SharedTerminal = undefined;
    try testing.expectEqual(
        Result.invalid_input,
        ghostty_terminal_producer_retain_terminal(null, &retained),
    );
    try testing.expect(retained == null);
    try testing.expectEqual(
        Result.invalid_input,
        ghostty_terminal_producer_retain_terminal(producer, null),
    );
    try testing.expectEqual(
        Result.invalid_input,
        ghostty_terminal_producer_feed(null, null, 0),
    );
    try testing.expectEqual(
        Result.invalid_input,
        ghostty_terminal_producer_feed(producer, null, 1),
    );
    try testing.expectEqual(
        Result.ok,
        ghostty_terminal_producer_feed(producer, null, 0),
    );
    ghostty_terminal_producer_free(null);
    ghostty_terminal_release(null);
}

test "terminal producer preserves parser state across feeds" {
    const testing = std.testing;
    const producer = try Producer.init(testing.allocator, .{
        .columns = 8,
        .rows = 3,
    });
    defer producer.deinit();

    producer.feed("\x1b[2;");
    try testing.expectEqual(@as(usize, 0), producer.terminal.terminal.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 0), producer.terminal.terminal.screens.active.cursor.y);

    producer.feed("3HX");
    try testing.expectEqual(@as(usize, 3), producer.terminal.terminal.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 1), producer.terminal.terminal.screens.active.cursor.y);
    const contents = try producer.terminal.terminal.plainString(testing.allocator);
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("\n  X", contents);
}

test "terminal producer feed preserves embedded NUL and explicit length" {
    const testing = std.testing;
    state.alloc = testing.allocator;
    const config: Config = .{
        .columns = 8,
        .rows = 2,
    };
    var producer: ?*Producer = null;
    try testing.expectEqual(
        Result.ok,
        ghostty_terminal_producer_new(&config, &producer),
    );
    defer ghostty_terminal_producer_free(producer);

    const bytes = "a\x00bignored";
    try testing.expectEqual(
        Result.ok,
        ghostty_terminal_producer_feed(producer, bytes.ptr, 3),
    );
    const contents = try producer.?.terminal.terminal.plainString(testing.allocator);
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("ab", contents);
}

test "terminal producer config controls size and scrollback" {
    const testing = std.testing;

    const without_scrollback = try Producer.init(testing.allocator, .{
        .columns = 7,
        .rows = 2,
        .max_scrollback = 0,
    });
    defer without_scrollback.deinit();
    try testing.expectEqual(@as(u16, 7), without_scrollback.terminal.terminal.cols);
    try testing.expectEqual(@as(u16, 2), without_scrollback.terminal.terminal.rows);
    try testing.expect(without_scrollback.terminal.terminal.screens.active.no_scrollback);
    without_scrollback.feed("one\r\ntwo\r\nthree");
    try testing.expectEqual(
        @as(usize, 2),
        without_scrollback.terminal.terminal.screens.active.pages.scrollbar().total,
    );

    const with_scrollback = try Producer.init(testing.allocator, .{
        .columns = 7,
        .rows = 2,
        .max_scrollback = 64 * 1024,
    });
    defer with_scrollback.deinit();
    try testing.expect(!with_scrollback.terminal.terminal.screens.active.no_scrollback);
    with_scrollback.feed("one\r\ntwo\r\nthree");
    try testing.expect(
        with_scrollback.terminal.terminal.screens.active.pages.scrollbar().total > 2,
    );
}

test "terminal producer and retained terminal have independent lifetimes" {
    const testing = std.testing;

    const producer_first = try Producer.init(testing.allocator, .{});
    var retained_after: ?*SharedTerminal = null;
    try testing.expectEqual(
        Result.ok,
        ghostty_terminal_producer_retain_terminal(producer_first, &retained_after),
    );
    producer_first.feed("producer first");
    ghostty_terminal_producer_free(producer_first);
    {
        defer ghostty_terminal_release(retained_after);
        retained_after.?.mutex.lock();
        defer retained_after.?.mutex.unlock();
        const contents = try retained_after.?.terminal.plainString(testing.allocator);
        defer testing.allocator.free(contents);
        try testing.expectEqualStrings("producer first", contents);
    }

    const producer_last = try Producer.init(testing.allocator, .{});
    var retained_before: ?*SharedTerminal = null;
    try testing.expectEqual(
        Result.ok,
        ghostty_terminal_producer_retain_terminal(producer_last, &retained_before),
    );
    ghostty_terminal_release(retained_before);
    producer_last.feed("producer last");
    const contents = try producer_last.terminal.terminal.plainString(testing.allocator);
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("producer last", contents);
    ghostty_terminal_producer_free(producer_last);
}

test "terminal producer partial initialization is allocation safe" {
    const testing = std.testing;
    var observed_success = false;

    for (0..256) |fail_index| {
        var failing = testing.FailingAllocator.init(
            testing.allocator,
            .{ .fail_index = fail_index },
        );
        const producer = Producer.init(failing.allocator(), .{}) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        producer.deinit();
        observed_success = true;
        break;
    }

    try testing.expect(observed_success);
}
