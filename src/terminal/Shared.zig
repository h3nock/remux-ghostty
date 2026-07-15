//! Shared ownership and synchronization for one terminal.
//!
//! Retain and release are thread-safe. Every terminal access after the owner
//! is published must hold `mutex`.

const Shared = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Terminal = @import("Terminal.zig");

alloc: Allocator,
ref_count: std.atomic.Value(usize),
mutex: std.Thread.Mutex = .{},
terminal: Terminal,

pub fn init(
    alloc: Allocator,
    options: Terminal.Options,
) Allocator.Error!*Shared {
    const self = try alloc.create(Shared);
    errdefer alloc.destroy(self);

    self.* = .{
        .alloc = alloc,
        .ref_count = .init(1),
        .terminal = try .init(alloc, options),
    };
    return self;
}

pub fn retain(self: *Shared) *Shared {
    const previous = self.ref_count.fetchAdd(1, .monotonic);
    assert(previous > 0);
    assert(previous < std.math.maxInt(usize));
    return self;
}

pub fn release(self: *Shared) void {
    const previous = self.ref_count.fetchSub(1, .acq_rel);
    assert(previous > 0);
    if (previous != 1) return;

    const alloc = self.alloc;
    self.terminal.deinit(alloc);
    alloc.destroy(self);
}

test "retained terminal survives its original owner" {
    const testing = std.testing;
    const shared = try Shared.init(testing.allocator, .{
        .cols = 10,
        .rows = 2,
    });
    const retained = shared.retain();
    shared.release();
    defer retained.release();

    retained.mutex.lock();
    defer retained.mutex.unlock();
    try retained.terminal.printString("alive");
    const contents = try retained.terminal.plainString(testing.allocator);
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("alive", contents);
}
