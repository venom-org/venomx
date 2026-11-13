pub const Vt = @import("vt").Vt;
pub const stream = @import("stream.zig");
pub const Pane = stream.Pane;
pub const Server = @import("server.zig").Server;
pub const Pty = @import("pty.zig").Pty;
test {
    _ = @import("os.zig");
    _ = @import("layout.zig");
    _ = @import("product.zig");
    _ = @import("run.zig");
    _ = @import("lifecycle.zig");
    _ = @import("spawn_env.zig");
    _ = @import("foreground.zig");
    _ = @import("shell_init.zig");
    _ = @import("scrub.zig");
    _ = @import("capture_rows.zig");
    _ = @import("recovery.zig");
    _ = @import("recovery_format.zig");
    _ = @import("recovery_store.zig");
    _ = @import("tests.zig");
    _ = @import("principal_events.zig");
    _ = @import("standalone.zig");
    _ = @import("keys.zig");
    _ = @import("keys_registry.zig");
    _ = @import("floats.zig");
    _ = @import("tmux_shim.zig");
}
