//! Types and functions related to tmux protocols.

const channel = @import("tmux/channel.zig");
const control = @import("tmux/control.zig");
const layout = @import("tmux/layout.zig");
pub const output = @import("tmux/output.zig");
pub const Channel = channel.Channel;
pub const ChannelAbortReason = channel.AbortReason;
pub const ChannelEvent = channel.Event;
pub const CommandFailure = channel.CommandFailure;
pub const CommandToken = channel.CommandToken;
pub const ControlClient = @import("tmux/client.zig").ControlClient;
pub const ControlParser = control.Parser;
pub const ControlNotification = control.Notification;
pub const Layout = layout.Layout;
pub const Viewer = @import("tmux/viewer.zig").Viewer;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("tmux/c.zig");
}
