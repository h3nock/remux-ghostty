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
renderer_claimed: std.atomic.Value(bool),
mutex: std.Thread.Mutex = .{},
terminal: Terminal,

pub const ClaimRendererError = error{RendererAlreadyClaimed};

pub fn init(
    alloc: Allocator,
    options: Terminal.Options,
) Allocator.Error!*Shared {
    const self = try alloc.create(Shared);
    errdefer alloc.destroy(self);

    self.* = .{
        .alloc = alloc,
        .ref_count = .init(1),
        .renderer_claimed = .init(false),
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

    assert(!self.renderer_claimed.load(.acquire));
    const alloc = self.alloc;
    self.terminal.deinit(alloc);
    alloc.destroy(self);
}

/// Claim exclusive renderer access to this terminal. Renderer claims are
/// lifecycle-only because independent renderers consume the same dirty state.
pub fn claimRenderer(self: *Shared) ClaimRendererError!void {
    if (self.renderer_claimed.cmpxchgStrong(
        false,
        true,
        .acquire,
        .monotonic,
    ) != null) return error.RendererAlreadyClaimed;
}

/// Release a live exclusive renderer claim.
pub fn releaseRenderer(self: *Shared) void {
    assert(self.renderer_claimed.swap(false, .release));
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

test "renderer claim is exclusive and reusable after release" {
    const testing = std.testing;
    const shared = try Shared.init(testing.allocator, .{
        .cols = 10,
        .rows = 2,
    });
    defer shared.release();

    try shared.claimRenderer();
    try testing.expectError(error.RendererAlreadyClaimed, shared.claimRenderer());
    shared.releaseRenderer();

    try shared.claimRenderer();
    shared.releaseRenderer();
}
