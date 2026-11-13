//! The notification after the first attach to a restored session:
//! `● restored 11 panes · 3 agents resumed · 4
//! session grants dropped │ ▲ 1 needs you: p4`. No splash; attach is
//! immediate.
const std = @import("std");

pub const id = "venomx.restored";
pub const ttl_ms: i64 = 10_000;

pub const Summary = struct {
    /// Restored panes the session still holds un-relaunched.
    panes: usize,
    /// Counts the client cannot know today (the daemon publishes
    /// neither): shown only when set.
    agents_resumed: ?usize = null,
    grants_dropped: ?usize = null,
    /// Panes whose attention is not `none`, in pane order.
    attention: []const []const u8 = &.{},
};

fn plural(n: usize, one: []const u8, many: []const u8) []const u8 {
    return if (n == 1) one else many;
}

/// The notice text. Caller frees.
pub fn format(a: std.mem.Allocator, s: Summary) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.print(a, "● restored {d} {s}", .{ s.panes, plural(s.panes, "pane", "panes") });
    if (s.agents_resumed) |n| try out.print(a, " · {d} {s} resumed", .{ n, plural(n, "agent", "agents") });
    if (s.grants_dropped) |n| if (n > 0) try out.print(a, " · {d} session {s} dropped", .{ n, plural(n, "grant", "grants") });
    if (s.attention.len > 0) {
        try out.print(a, " │ ▲ {d} needs you: ", .{s.attention.len});
        for (s.attention, 0..) |p, i| {
            if (i > 0) try out.appendSlice(a, ", ");
            try out.appendSlice(a, p);
        }
    }
    return out.toOwnedSlice(a);
}

test "the documented example, in full" {
    const t = try format(std.testing.allocator, .{ .panes = 11, .agents_resumed = 3, .grants_dropped = 4, .attention = &.{"p4"} });
    defer std.testing.allocator.free(t);
    try std.testing.expectEqualStrings("● restored 11 panes · 3 agents resumed · 4 session grants dropped │ ▲ 1 needs you: p4", t);
}

test "a restore that dropped nothing has no dropped part; unknown counts are left out" {
    const a = std.testing.allocator;
    const zero = try format(a, .{ .panes = 11, .agents_resumed = 3, .grants_dropped = 0 });
    defer a.free(zero);
    try std.testing.expectEqualStrings("● restored 11 panes · 3 agents resumed", zero);
    const unknown = try format(a, .{ .panes = 1 });
    defer a.free(unknown);
    try std.testing.expectEqualStrings("● restored 1 pane", unknown);
}
