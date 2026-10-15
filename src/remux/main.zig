//! Code this fork adds to Ghostty for Remux. It lives here, apart from
//! upstream's files, so syncing with upstream rarely touches it.

pub const tmux = @import("tmux.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
