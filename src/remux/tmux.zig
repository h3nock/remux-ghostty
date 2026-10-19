//! Remux's tmux control-mode client: a control parser that doesn't depend
//! on the transport, a viewer whose pane terminals the renderer shares, and
//! a command channel. Ghostty's own tmux integration keeps using upstream's
//! `terminal/tmux`.

const channel = @import("tmux/channel.zig");
const control = @import("tmux/control.zig");
pub const output = @import("tmux/output.zig");
pub const Channel = channel.Channel;
pub const ChannelAbortReason = channel.AbortReason;
pub const ChannelEvent = channel.Event;
pub const CommandFailure = channel.CommandFailure;
pub const CommandToken = channel.CommandToken;
pub const ControlClient = @import("tmux/client.zig").ControlClient;
pub const ControlParser = control.Parser;
pub const ControlNotification = control.Notification;
pub const Viewer = @import("tmux/viewer.zig").Viewer;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("tmux/c.zig");
    _ = @import("tmux/resize.zig");
}
