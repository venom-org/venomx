//! Client-local geometry for the daemon's shared flat preorder tree. Splits
//! divide by their shared ratio, equally by default (the first child takes the
//! extra cell), with a one-cell separator. Too-small rectangles are clipped to
//! zero, never deleted.
const std = @import("std");
const shared = @import("layout.zig");
const Node = shared.Node;

pub const Rect = struct { x: u16 = 0, y: u16 = 0, width: u16 = 0, height: u16 = 0 };
pub const Leaf = struct { pane: []const u8, rect: Rect };
pub const Separator = struct { rect: Rect, vertical: bool };
pub const Layout = struct {
    leaves: std.ArrayList(Leaf) = .empty,
    separators: std.ArrayList(Separator) = .empty,
    pub fn deinit(self: *Layout, a: std.mem.Allocator) void {
        self.leaves.deinit(a);
        self.separators.deinit(a);
    }
};

/// `nodes` must satisfy `layout.valid`; leaf pane IDs borrow from it.
pub fn compute(a: std.mem.Allocator, nodes: []const Node, area: Rect) !Layout {
    var out: Layout = .{};
    errdefer out.deinit(a);
    if (nodes.len > 0) try walk(a, &out, nodes, 0, area);
    return out;
}
fn walk(a: std.mem.Allocator, out: *Layout, nodes: []const Node, index: usize, r: Rect) !void {
    const n = nodes[index];
    if (n.kind == .pane) return out.leaves.append(a, .{ .pane = n.pane.?, .rect = r });
    const cols = n.axis.? == .cols;
    const total = if (cols) r.width else r.height;
    const avail = total -| 1;
    const first: u16 = @intCast(shared.firstShare(n.ratio, avail));
    const second = avail - first;
    var one = r;
    var two = r;
    var sep = r;
    if (cols) {
        one.width = first;
        sep.x = r.x +| first;
        sep.width = @min(total, 1);
        two.x = sep.x +| sep.width;
        two.width = second;
    } else {
        one.height = first;
        sep.y = r.y +| first;
        sep.height = @min(total, 1);
        two.y = sep.y +| sep.height;
        two.height = second;
    }
    if (sep.width > 0 and sep.height > 0) try out.separators.append(a, .{ .rect = sep, .vertical = cols });
    try walk(a, out, nodes, n.first.?, one);
    try walk(a, out, nodes, n.second.?, two);
}

/// Where the first child of `split` ends on `area` (its width or height along
/// `axis`), or null when `split` is not laid out.
fn dividerAt(nodes: []const Node, index: usize, split: usize, r: Rect) ?u16 {
    const n = nodes[index];
    if (n.kind == .pane) return null;
    const cols = n.axis.? == .cols;
    const total = if (cols) r.width else r.height;
    const first: u16 = @intCast(shared.firstShare(n.ratio, total -| 1));
    if (index == split) return first;
    var one = r;
    var two = r;
    if (cols) {
        one.width = first;
        two.x = r.x +| first +| 1;
        two.width = total -| 1 -| first;
    } else {
        one.height = first;
        two.y = r.y +| first +| 1;
        two.height = total -| 1 -| first;
    }
    return dividerAt(nodes, n.first.?, split, one) orelse dividerAt(nodes, n.second.?, split, two);
}
/// `pane.resize` counts `cells` on the panes' PTY sizes, which
/// `sizes.extent(pane, axis)` gives, because the daemon knows no viewport. This
/// is the fewest PTY cells in `direction` (`delta` is -1 for left/up, 1 for
/// right/down) that move the divider of `pane`'s nearest split on `axis` by at
/// least one cell of this client's own `area`. 1 when no count does (the
/// divider is at its limit, or there is no such split).
pub fn pressCells(a: std.mem.Allocator, nodes: []const Node, pane: []const u8, axis: shared.Axis, delta: i64, area: Rect, sizes: anytype) !u32 {
    const probe = try a.dupe(Node, nodes);
    defer a.free(probe);
    var before: ?u16 = null;
    var last_moved: u32 = 0;
    var n: u32 = 1;
    while (n <= 65535) : (n += 1) {
        const move = shared.moveDivider(nodes, pane, axis, delta * @as(i64, n), sizes) orelse return 1;
        if (move.moved == last_moved and n > 1) return 1;
        last_moved = move.moved;
        const was = before orelse blk: {
            before = dividerAt(nodes, 0, move.split, area) orelse return 1;
            break :blk before.?;
        };
        probe[move.split].ratio = move.ratio;
        defer probe[move.split].ratio = nodes[move.split].ratio;
        if (dividerAt(probe, 0, move.split, area)) |now| if (now != was) return n;
    }
    return 1;
}

test "equal shares, separators and clipping without dropping leaves" {
    const a = std.testing.allocator;
    const nodes = [_]Node{
        .{ .kind = .split, .axis = .cols, .first = 1, .second = 2 },
        .{ .kind = .pane, .pane = "p0" },
        .{ .kind = .split, .axis = .rows, .first = 3, .second = 4 },
        .{ .kind = .pane, .pane = "p1" },
        .{ .kind = .pane, .pane = "p2" },
    };
    var l = try compute(a, &nodes, .{ .width = 80, .height = 24 });
    defer l.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), l.leaves.items.len);
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 40, .height = 24 }, l.leaves.items[0].rect);
    try std.testing.expectEqual(Rect{ .x = 41, .y = 0, .width = 39, .height = 12 }, l.leaves.items[1].rect);
    try std.testing.expectEqual(Rect{ .x = 41, .y = 13, .width = 39, .height = 11 }, l.leaves.items[2].rect);
    try std.testing.expectEqual(@as(usize, 2), l.separators.items.len);
    var tiny = try compute(a, &nodes, .{ .width = 1, .height = 1 });
    defer tiny.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), tiny.leaves.items.len);
    try std.testing.expectEqual(@as(u16, 0), tiny.leaves.items[0].rect.width);
    var empty = try compute(a, &.{}, .{ .width = 10, .height = 10 });
    defer empty.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), empty.leaves.items.len);
}
test "a split's ratio divides its cells, the same for every viewport share" {
    const a = std.testing.allocator;
    const nodes = [_]Node{
        .{ .kind = .split, .axis = .cols, .first = 1, .second = 2, .ratio = 2500 },
        .{ .kind = .pane, .pane = "p0" },
        .{ .kind = .pane, .pane = "p1" },
    };
    var wide = try compute(a, &nodes, .{ .width = 81, .height = 24 });
    defer wide.deinit(a);
    try std.testing.expectEqual(Rect{ .width = 20, .height = 24 }, wide.leaves.items[0].rect);
    try std.testing.expectEqual(Rect{ .x = 21, .width = 60, .height = 24 }, wide.leaves.items[1].rect);
    var narrow = try compute(a, &nodes, .{ .width = 41, .height = 24 });
    defer narrow.deinit(a);
    try std.testing.expectEqual(@as(u16, 10), narrow.leaves.items[0].rect.width);
    try std.testing.expectEqual(@as(u16, 30), narrow.leaves.items[1].rect.width);
}

test "every press moves the divider on the pressing client's own viewport" {
    const a = std.testing.allocator;
    const Sizes = struct {
        pty: u32,
        pub fn extent(ctx: @This(), _: []const u8, on: shared.Axis) u32 {
            return if (on == .cols) ctx.pty else 10;
        }
    };
    // Two panes whose PTYs are 80 wide each (161 cells with the separator),
    // pressed on a client that has 81 cells and one that has 161.
    for ([_]u16{ 81, 161, 40 }) |width| {
        var nodes = [_]Node{
            .{ .kind = .split, .axis = .cols, .first = 1, .second = 2 },
            .{ .kind = .pane, .pane = "p0" },
            .{ .kind = .pane, .pane = "p1" },
        };
        const area: Rect = .{ .width = width, .height = 24 };
        for (0..10) |_| {
            const cells = try pressCells(a, &nodes, "p0", .cols, 1, area, Sizes{ .pty = 80 });
            const before = (try compute(a, &nodes, area));
            var b = before;
            defer b.deinit(a);
            const move = shared.moveDivider(&nodes, "p0", .cols, cells, Sizes{ .pty = 80 }).?;
            nodes[0].ratio = move.ratio;
            var after = try compute(a, &nodes, area);
            defer after.deinit(a);
            try std.testing.expect(after.leaves.items[0].rect.width > b.leaves.items[0].rect.width);
        }
    }
}

test "pressCells with no split, at a limit, on rows, nested, and on a narrow viewport" {
    const a = std.testing.allocator;
    const Sizes = struct {
        cols: u32,
        rows: u32,
        pub fn extent(ctx: @This(), _: []const u8, on: shared.Axis) u32 {
            return if (on == .cols) ctx.cols else ctx.rows;
        }
    };
    const sizes = Sizes{ .cols = 80, .rows = 24 };
    const area: Rect = .{ .width = 81, .height = 25 };
    const one = [_]Node{.{ .kind = .pane, .pane = "p0" }};
    // No split at all, and no split on the axis asked for: one cell, nothing moves.
    try std.testing.expectEqual(@as(u32, 1), try pressCells(a, &one, "p0", .cols, 1, area, sizes));
    const side = [_]Node{
        .{ .kind = .split, .axis = .cols, .first = 1, .second = 2 },
        .{ .kind = .pane, .pane = "p0" },
        .{ .kind = .pane, .pane = "p1" },
    };
    try std.testing.expectEqual(@as(u32, 1), try pressCells(a, &side, "p0", .rows, 1, area, sizes));
    // A divider at its limit: 1, because no count moves it.
    var limit = side;
    limit[0].ratio = 1;
    try std.testing.expectEqual(@as(u32, 1), try pressCells(a, &limit, "p0", .cols, -1, area, sizes));
    // Narrow viewport: 161 PTY cells on 81. A press needs one PTY cell where
    // rounding helps and two where it does not, and always moves the divider.
    var most: u32 = 0;
    var ratio: u16 = 4000;
    while (ratio < 6000) : (ratio += 7) {
        var t = side;
        t[0].ratio = ratio;
        for ([_]i64{ 1, -1 }) |sign| {
            const cells = try pressCells(a, &t, "p0", .cols, sign, area, sizes);
            most = @max(most, cells);
            const was = dividerAt(&t, 0, 0, area).?;
            t[0].ratio = shared.moveDivider(&t, "p0", .cols, sign * @as(i64, cells), sizes).?.ratio;
            try std.testing.expect(dividerAt(&t, 0, 0, area).? != was);
            t[0].ratio = ratio;
        }
    }
    try std.testing.expectEqual(@as(u32, 2), most);
    // Rows with delta -1 (up), 49 PTY rows on 25.
    const stack = [_]Node{
        .{ .kind = .split, .axis = .rows, .first = 1, .second = 2 },
        .{ .kind = .pane, .pane = "p0" },
        .{ .kind = .pane, .pane = "p1" },
    };
    for ([_][]const u8{ "p0", "p1" }) |id| {
        const cells = try pressCells(a, &stack, id, .rows, -1, area, sizes);
        try std.testing.expect(cells >= 1 and cells <= 2);
        var t = stack;
        const was = dividerAt(&t, 0, 0, area).?;
        t[0].ratio = shared.moveDivider(&t, id, .rows, -@as(i64, cells), sizes).?.ratio;
        try std.testing.expect(dividerAt(&t, 0, 0, area).? < was);
    }
    // Nested: p1 sits in a rows split inside the cols split; its cols press moves the outer divider.
    const nested = [_]Node{
        .{ .kind = .split, .axis = .cols, .first = 1, .second = 2 },
        .{ .kind = .pane, .pane = "p0" },
        .{ .kind = .split, .axis = .rows, .first = 3, .second = 4 },
        .{ .kind = .pane, .pane = "p1" },
        .{ .kind = .pane, .pane = "p2" },
    };
    const outer = try pressCells(a, &nested, "p2", .cols, -1, area, sizes);
    var moved = nested;
    moved[0].ratio = shared.moveDivider(&nested, "p2", .cols, -@as(i64, outer), sizes).?.ratio;
    try std.testing.expect(dividerAt(&moved, 0, 0, area).? < dividerAt(&nested, 0, 0, area).?);
    const inner = try pressCells(a, &nested, "p2", .rows, -1, area, sizes);
    moved = nested;
    moved[2].ratio = shared.moveDivider(&nested, "p2", .rows, -@as(i64, inner), sizes).?.ratio;
    try std.testing.expect(dividerAt(&moved, 0, 2, area).? < dividerAt(&nested, 0, 2, area).?);
    // On the viewport the PTYs are, one cell is enough.
    try std.testing.expectEqual(@as(u32, 1), try pressCells(a, &nested, "p2", .cols, -1, .{ .width = 161, .height = 49 }, sizes));
}
