//! The notification for a denied write to another pane:
//! `✕ p3 was denied write on p5 (pane.send)`, with the `danger` mark. Fed by
//! `principal.created` (which pane a principal is) and
//! `principal.denied`. The target pane is never touched.
const std = @import("std");

pub const ttl_ms: i64 = 10_000;
/// More principals than this and the oldest is dropped; a dropped principal
/// is named by its ID instead of its pane.
/// Principals as the daemon announced them: `principal.created` and the
/// `grant.list` read at attach (the snapshot carries none). Enough to name a
/// denied principal by the nearest pane on its parent chain.
pub const Panes = struct {
    const Entry = struct { principal: []u8, pane: ?[]u8, parent: ?[]u8 };
    pub const max_known = max_known_default;
    /// A parent chain is a tree depth; anything longer is not followed.
    const max_walk = 8;
    list: std.ArrayList(Entry) = .empty,

    pub fn deinit(self: *Panes, a: std.mem.Allocator) void {
        for (self.list.items) |e| freeEntry(a, e);
        self.list.deinit(a);
    }
    fn freeEntry(a: std.mem.Allocator, e: Entry) void {
        a.free(e.principal);
        if (e.pane) |x| a.free(x);
        if (e.parent) |x| a.free(x);
    }
    pub fn learn(self: *Panes, a: std.mem.Allocator, principal: []const u8, pane: ?[]const u8, parent: ?[]const u8) !void {
        // Make room first, so a failed allocation below loses nothing new.
        try self.list.ensureUnusedCapacity(a, 1);
        const p = try a.dupe(u8, principal);
        errdefer a.free(p);
        const n: ?[]u8 = if (pane) |x| try a.dupe(u8, x) else null;
        errdefer if (n) |x| a.free(x);
        const q: ?[]u8 = if (parent) |x| try a.dupe(u8, x) else null;
        errdefer if (q) |x| a.free(x);
        self.forget(a, principal);
        if (self.list.items.len >= max_known) self.drop(a, 0);
        self.list.appendAssumeCapacity(.{ .principal = p, .pane = n, .parent = q });
    }
    pub fn forget(self: *Panes, a: std.mem.Allocator, principal: []const u8) void {
        for (self.list.items, 0..) |e, i| if (std.mem.eql(u8, e.principal, principal)) return self.drop(a, i);
    }
    fn drop(self: *Panes, a: std.mem.Allocator, i: usize) void {
        freeEntry(a, self.list.orderedRemove(i));
    }
    fn find(self: *const Panes, principal: []const u8) ?*const Entry {
        for (self.list.items) |*e| if (std.mem.eql(u8, e.principal, principal)) return e;
        return null;
    }
    /// The pane of `principal`, or of its nearest ancestor that has one
    /// (an agent's token principal is named by the pane it runs in).
    pub fn paneOf(self: *const Panes, principal: []const u8) ?[]const u8 {
        var at = principal;
        for (0..max_walk) |_| {
            const e = self.find(at) orelse return null;
            if (e.pane) |x| return x;
            at = e.parent orelse return null;
        }
        return null;
    }
};
const max_known_default = 256;

/// The pane id in a `pane:<id>` resource, or null for any other resource.
pub fn targetPane(resource: ?[]const u8) ?[]const u8 {
    const r = resource orelse return null;
    const prefix = "pane:";
    if (!std.mem.startsWith(u8, r, prefix) or r.len == prefix.len) return null;
    return r[prefix.len..];
}

/// The notice text. Caller frees. `who` is the denied pane, or its principal.
pub fn format(a: std.mem.Allocator, who: []const u8, target: []const u8, verb: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "✕ {s} was denied write on {s} ({s})", .{ who, target, verb });
}

/// Notification id: one per (who, target), so a repeat replaces its notice.
pub fn noteId(a: std.mem.Allocator, who: []const u8, target: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "venomx.denied.{s}.{s}", .{ who, target });
}

test "the documented example" {
    const t = try format(std.testing.allocator, "p3", "p5", "pane.send");
    defer std.testing.allocator.free(t);
    try std.testing.expectEqualStrings("✕ p3 was denied write on p5 (pane.send)", t);
}

test "targetPane takes only pane resources" {
    try std.testing.expectEqualStrings("p5", targetPane("pane:p5").?);
    try std.testing.expect(targetPane("pane:") == null);
    try std.testing.expect(targetPane("window:w1") == null);
    try std.testing.expect(targetPane(null) == null);
}

test "Panes learns, replaces and forgets" {
    const a = std.testing.allocator;
    var m: Panes = .{};
    defer m.deinit(a);
    try m.learn(a, "g3", "p3", "owner");
    try m.learn(a, "g3", "p4", "owner");
    try std.testing.expectEqualStrings("p4", m.paneOf("g3").?);
    m.forget(a, "g3");
    try std.testing.expect(m.paneOf("g3") == null);
}

test "paneOf walks to the nearest pane, bounded" {
    const a = std.testing.allocator;
    var m: Panes = .{};
    defer m.deinit(a);
    try m.learn(a, "g3", "p3", "owner");
    try m.learn(a, "g4", null, "g3");
    try m.learn(a, "g5", null, "g4");
    try std.testing.expectEqualStrings("p3", m.paneOf("g5").?);
    try m.learn(a, "g6", null, "owner");
    try std.testing.expect(m.paneOf("g6") == null);
    // A parent cycle ends at the bound.
    try m.learn(a, "g7", null, "g8");
    try m.learn(a, "g8", null, "g7");
    try std.testing.expect(m.paneOf("g7") == null);
}

test "learn survives allocation failure at every point" {
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        var fa = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = i });
        const a = fa.allocator();
        var m: Panes = .{};
        defer m.deinit(a);
        m.learn(a, "g3", "p3", "owner") catch continue;
        m.learn(a, "g3", "p4", "owner") catch continue;
    }
}
