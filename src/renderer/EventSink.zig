//! Renderer-originated events delivered to the owning surface.
//!
//! The context pointer and vtable must remain valid for the full lifetime of
//! every renderer and renderer thread that uses the sink. Callbacks may run
//! off the main thread.
pub const EventSink = @This();

const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    /// Returns true when the value was accepted. False asks the renderer to
    /// keep the value dirty and retry delivery on its next draw.
    scrollbar: *const fn (ptr: *anyopaque, value: terminal.Scrollbar) bool,
    renderer_health: *const fn (ptr: *anyopaque, value: renderer.Health) void,
    redraw: *const fn (ptr: *anyopaque) void,
};

pub inline fn scrollbar(self: EventSink, value: terminal.Scrollbar) bool {
    return self.vtable.scrollbar(self.ptr, value);
}

pub inline fn rendererHealth(self: EventSink, value: renderer.Health) void {
    self.vtable.renderer_health(self.ptr, value);
}

pub inline fn redraw(self: EventSink) void {
    self.vtable.redraw(self.ptr);
}

test "dispatches renderer events" {
    const testing = @import("std").testing;

    const Context = struct {
        scrollbar_value: terminal.Scrollbar = .zero,
        scrollbar_accepted: bool = false,
        health_value: renderer.Health = .healthy,
        redraw_count: usize = 0,

        fn scrollbar(ptr: *anyopaque, value: terminal.Scrollbar) bool {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.scrollbar_value = value;
            return self.scrollbar_accepted;
        }

        fn rendererHealth(ptr: *anyopaque, value: renderer.Health) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.health_value = value;
        }

        fn redraw(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.redraw_count += 1;
        }
    };

    const vtable: VTable = .{
        .scrollbar = Context.scrollbar,
        .renderer_health = Context.rendererHealth,
        .redraw = Context.redraw,
    };
    var context: Context = .{};
    const sink: EventSink = .{
        .ptr = &context,
        .vtable = &vtable,
    };

    const value: terminal.Scrollbar = .{
        .total = 10,
        .offset = 2,
        .len = 4,
    };
    try testing.expect(!sink.scrollbar(value));
    try testing.expect(context.scrollbar_value.eql(value));
    context.scrollbar_accepted = true;
    try testing.expect(sink.scrollbar(value));

    sink.rendererHealth(.unhealthy);
    try testing.expectEqual(renderer.Health.unhealthy, context.health_value);

    sink.redraw();
    try testing.expectEqual(@as(usize, 1), context.redraw_count);
}
