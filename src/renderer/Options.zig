//! The options that are used to configure a renderer.

const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const renderer = @import("../renderer.zig");

/// The derived configuration for this renderer implementation.
config: renderer.Renderer.DerivedConfig,

/// The font grid that should be used along with the key for deref-ing.
font_grid: *font.SharedGrid,

/// The size of everything.
size: renderer.Size,

/// Where surface messages go: the core surface's mailbox, or callbacks for
/// owners without one. This is only valid once the thread has started and
/// should not be used outside of the thread.
event_sink: renderer.EventSink,

/// The apprt surface.
rt_surface: *apprt.RendererSurface,

/// The renderer thread.
thread: *renderer.Thread,
