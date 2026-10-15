//! Code this fork adds to Ghostty for Remux. It lives here, apart from
//! upstream's files, so syncing with upstream rarely touches it.

pub const Runtime = @import("Runtime.zig");
pub const Shared = @import("Shared.zig");
pub const TerminalSurface = @import("TerminalSurface.zig");
pub const link = @import("link.zig");
pub const terminal_config = @import("terminal_config.zig");
pub const tmux = @import("tmux.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
