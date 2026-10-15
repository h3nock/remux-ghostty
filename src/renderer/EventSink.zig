const apprt = @import("../apprt.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");

/// Renderer-originated events delivered to the renderer's owner. A core
/// surface receives them through its mailbox. Owners without a core surface
/// receive them through callbacks, which may run off the main thread.
pub const EventSink = union(enum) {
    surface_mailbox: apprt.surface.Mailbox,
    callbacks: Callbacks,

    /// The context pointer and vtable must remain valid for the full lifetime
    /// of every renderer and renderer thread that uses the sink.
    pub const Callbacks = struct {
        ptr: *anyopaque,
        vtable: *const VTable,
    };

    pub const VTable = struct {
        /// Returns true when the value was accepted. False asks the renderer
        /// to keep the value dirty and retry delivery on its next draw.
        scrollbar: *const fn (ptr: *anyopaque, value: terminal.Scrollbar) bool,
        renderer_health: *const fn (ptr: *anyopaque, value: renderer.Health) void,
        /// The renderer exported a new frame for the owner to present.
        redraw: *const fn (ptr: *anyopaque) void,
    };

    pub fn scrollbar(self: EventSink, value: terminal.Scrollbar) bool {
        return switch (self) {
            .surface_mailbox => |mailbox| mailbox.push(.{
                .scrollbar = value,
            }, .instant) > 0,
            .callbacks => |c| c.vtable.scrollbar(c.ptr, value),
        };
    }

    pub fn rendererHealth(self: EventSink, value: renderer.Health) void {
        switch (self) {
            .surface_mailbox => |mailbox| _ = mailbox.push(.{
                .renderer_health = value,
            }, .{ .forever = {} }),
            .callbacks => |c| c.vtable.renderer_health(c.ptr, value),
        }
    }

    pub fn redraw(self: EventSink) void {
        switch (self) {
            .surface_mailbox => |mailbox| _ = mailbox.push(
                .redraw,
                .{ .forever = {} },
            ),
            .callbacks => |c| c.vtable.redraw(c.ptr),
        }
    }
};

test "callbacks receive renderer events" {
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

    const vtable: EventSink.VTable = .{
        .scrollbar = Context.scrollbar,
        .renderer_health = Context.rendererHealth,
        .redraw = Context.redraw,
    };
    var context: Context = .{};
    const sink: EventSink = .{ .callbacks = .{
        .ptr = &context,
        .vtable = &vtable,
    } };

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
