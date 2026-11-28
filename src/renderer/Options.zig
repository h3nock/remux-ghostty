//! The options that are used to configure a renderer.

const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const renderer = @import("../renderer.zig");

/// The device state that corresponds to the physical GPU
/// we'd like to render to.
device: *renderer.Device,

/// The derived configuration for this renderer implementation.
config: renderer.Renderer.DerivedConfig,

/// The font grid that should be used along with the key for deref-ing.
font_grid: *font.SharedGrid,

/// The size of everything.
size: renderer.Size,

/// Whether a backend sizes the terminal's grid, as tmux does for a pane's
/// mirror, and the embedder resizes the surface to that grid after it hears
/// of it. The renderer then keeps its last frame while the drawable holds
/// another grid than the cells (remux/backend_sized_grid.zig). Elsewhere the
/// grid follows the surface, and drawing the old cells at the new size is
/// what a resize should show.
backend_sized_grid: bool = false,

/// Where surface messages go: the core surface's mailbox, or callbacks for
/// owners without one. This is only valid once the thread has started and
/// should not be used outside of the thread.
event_sink: renderer.EventSink,

/// The apprt surface.
rt_surface: *apprt.RendererSurface,

/// The renderer thread.
thread: *renderer.Thread,
