//! Immutable flat preorder topology. Edits allocate a replacement; callers
//! validate and stage all other state before exchanging the published slice.
const std = @import("std");
pub const Axis = enum { cols, rows };
/// A split's `ratio` is the first child's share of the cells the separator
/// leaves, in 1/10000. Null is an equal split, and `moveDivider` never stores
/// the equal value, so a layout nobody resized reads as it always did.
pub const ratio_scale: u32 = 10000;
pub const Node = struct {
    kind: enum { pane, split },
    pane: ?[]const u8 = null,
    axis: ?Axis = null,
    first: ?usize = null,
    second: ?usize = null,
    ratio: ?u16 = null,
};
pub fn validRatio(ratio: u64) bool {
    return ratio >= 1 and ratio < ratio_scale;
}
/// The first child's cells out of `avail`; the second child gets the rest.
/// Rounding up gives the first child the extra cell of an equal split. A child
/// keeps at least one cell while there are two to share.
pub fn firstShare(ratio: ?u16, avail: u32) u32 {
    if (avail < 2) return avail;
    const r: u64 = ratio orelse ratio_scale / 2;
    const share: u32 = @intCast((avail * r + ratio_scale - 1) / ratio_scale);
    return std.math.clamp(share, 1, avail - 1);
}
pub fn valid(nodes: []const Node) bool {
    if (nodes.len == 0) return true;
    var next: usize = 0;
    if (!walk(nodes, 0, &next) or next != nodes.len) return false;
    for (nodes, 0..) |n, i| if (n.kind == .pane) {
        for (nodes[0..i]) |prev| if (prev.pane != null and std.mem.eql(u8, prev.pane.?, n.pane.?)) return false;
    };
    return true;
}
fn walk(nodes: []const Node, index: usize, next: *usize) bool {
    if (index != next.* or index >= nodes.len) return false;
    const n = nodes[index];
    next.* += 1;
    return switch (n.kind) {
        .pane => n.pane != null and n.axis == null and n.first == null and n.second == null and n.ratio == null,
        .split => n.pane == null and n.axis != null and n.first != null and n.second != null and (n.ratio == null or validRatio(n.ratio.?)) and walk(nodes, n.first.?, next) and walk(nodes, n.second.?, next),
    };
}
pub fn edit(a: std.mem.Allocator, old: []const Node, target: []const u8, addition: ?Node) ![]Node {
    var out: std.ArrayList(Node) = .empty;
    errdefer out.deinit(a);
    if (old.len > 0) try copy(a, &out, old, 0, target, addition);
    const owned = try out.toOwnedSlice(a);
    std.debug.assert(valid(owned));
    return owned;
}
/// Relaunch: the same tree with one leaf's pane ID exchanged.
pub fn replace(a: std.mem.Allocator, old: []const Node, target: []const u8, pane: []const u8) ![]Node {
    const out = try a.dupe(Node, old);
    var found = false;
    for (out) |*n| if (isTarget(n.*, target)) {
        n.pane = pane;
        found = true;
    };
    std.debug.assert(found and valid(out));
    return out;
}
fn isTarget(n: Node, target: []const u8) bool {
    return n.kind == .pane and std.mem.eql(u8, n.pane.?, target);
}
fn copy(a: std.mem.Allocator, out: *std.ArrayList(Node), old: []const Node, index: usize, target: []const u8, addition: ?Node) !void {
    const n = old[index];
    if (isTarget(n, target)) {
        if (addition) |new| {
            const start = out.items.len;
            try out.appendSlice(a, &.{ .{ .kind = .split, .axis = new.axis, .first = start + 1, .second = start + 2 }, n, .{ .kind = .pane, .pane = new.pane } });
        }
        return;
    }
    if (n.kind == .pane) return out.append(a, n);
    if (addition == null) {
        if (isTarget(old[n.first.?], target)) return copy(a, out, old, n.second.?, target, null);
        if (isTarget(old[n.second.?], target)) return copy(a, out, old, n.first.?, target, null);
    }
    const start = out.items.len;
    try out.append(a, .{ .kind = .split, .axis = n.axis, .first = start + 1, .ratio = n.ratio });
    try copy(a, out, old, n.first.?, target, addition);
    out.items[start].second = out.items.len;
    try copy(a, out, old, n.second.?, target, addition);
}
/// What moving a divider changes: `nodes[split].ratio` becomes `ratio`.
pub const Move = struct { split: usize, ratio: ?u16, moved: u32 };
/// `pane.resize`: move the divider of `pane`'s nearest ancestor
/// split on `axis` by `delta` cells, positive toward the end of the axis (right
/// or down), stopping at a child's minimum and never moving against `delta`,
/// even when the divider already sits past that minimum. Null when nothing
/// moves. `sizes.extent(pane_id, axis)` gives a leaf's cells: the tree holds
/// shares and no viewport, so a cell here is one on the viewport the panes last
/// took, and another client's viewport moves the same share.
pub fn moveDivider(nodes: []const Node, pane: []const u8, axis: Axis, delta: i64, sizes: anytype) ?Move {
    const split = nearestSplit(nodes, pane, axis) orelse return null;
    const n = nodes[split];
    const avail = extent(nodes, n.first.?, axis, sizes) + extent(nodes, n.second.?, axis, sizes);
    const min_first = minExtent(nodes, n.first.?, axis);
    const min_second = minExtent(nodes, n.second.?, axis);
    if (avail < min_first + min_second) return null;
    const current = firstShare(n.ratio, avail);
    const limit = if (delta < 0) @min(current, @max(@as(i64, current) + delta, min_first)) else @max(current, @min(@as(i64, current) + delta, avail - min_second));
    const scaled: u16 = @intCast(std.math.clamp(@as(u64, @intCast(limit)) * ratio_scale / avail, 1, ratio_scale - 1));
    // Past 10000 cells a ratio can't name every cell: what it reads back counts.
    const share = firstShare(scaled, avail);
    if (if (delta < 0) share >= current or share < min_first else share <= current) return null;
    const ratio: ?u16 = if (share == firstShare(null, avail)) null else scaled;
    return .{ .split = split, .ratio = ratio, .moved = @max(share, current) - @min(share, current) };
}
/// `edit` adding a split, for a new pane next to `target`. Space
/// is what the tree already had. Walking the target's ancestors from the root
/// down, on the panes' current sizes, an ancestor with a ratio whose child
/// holding `target` the split raised above its cells gets its ratio clamped:
/// the divider moves just far enough, taking cells only from the other child,
/// which keeps its own minimum. The ratio goes back to equal only when the
/// cells can't hold both minimums. Every other ancestor keeps its ratio, even
/// one whose other child is already below its minimum.
pub fn editSplit(a: std.mem.Allocator, old: []const Node, target: []const u8, addition: Node, sizes: anytype) ![]Node {
    const out = try edit(a, old, target, addition);
    const t = for (old, 0..) |n, i| {
        if (isTarget(n, target)) break i;
    } else return out;
    // The cells of the subtree on the path, on each axis, as the splits above it divide them.
    var cells = [2]u32{ extent(old, 0, .cols, sizes), extent(old, 0, .rows, sizes) };
    // Preorder: the ancestors of `target` precede it and keep their index in `out`,
    // and `target` is in an ancestor's first subtree exactly when it precedes the second.
    var i: usize = 0;
    while (i != t) {
        const n = old[i];
        const axis = n.axis.?;
        const in_first = t < n.second.?;
        const avail = cells[@backingInt(axis)] -| 1;
        var share = firstShare(n.ratio, avail);
        if (n.ratio != null) {
            const min_first = minExtent(out, out[i].first.?, axis);
            const min_second = minExtent(out, out[i].second.?, axis);
            const raised = if (in_first) min_first > minExtent(old, n.first.?, axis) else min_second > minExtent(old, n.second.?, axis);
            const short = if (in_first) share < min_first else avail - share < min_second;
            if (raised and short) {
                out[i].ratio = if (avail < min_first + min_second) null else clampedRatio(avail, if (in_first) min_first else min_second, in_first);
                share = firstShare(out[i].ratio, avail);
            }
        }
        cells[@backingInt(axis)] = if (in_first) share else avail - share;
        i = if (in_first) n.first.? else n.second.?;
    }
    std.debug.assert(valid(out));
    return out;
}
/// The ratio that gives the child holding the new pane at least `need` of `avail`
/// cells, null when that is the equal split. Past 10000 cells a ratio can't name
/// every cell, and rounding favors that child.
fn clampedRatio(avail: u32, need: u32, in_first: bool) ?u16 {
    // First: the smallest ratio whose rounded-up share reaches `need`.
    // Second: the largest whose share leaves it `need`.
    const r: u64 = if (in_first) @as(u64, need - 1) * ratio_scale / avail + 1 else @as(u64, avail - need) * ratio_scale / avail;
    const scaled: u16 = @intCast(std.math.clamp(r, 1, ratio_scale - 1));
    return if (firstShare(scaled, avail) == firstShare(null, avail)) null else scaled;
}
fn nearestSplit(nodes: []const Node, pane: []const u8, axis: Axis) ?usize {
    var child = for (nodes, 0..) |n, i| {
        if (isTarget(n, pane)) break i;
    } else return null;
    // Preorder: a parent always precedes its children.
    var i = child;
    while (i > 0) {
        i -= 1;
        const n = nodes[i];
        if (n.kind != .split or (n.first.? != child and n.second.? != child)) continue;
        if (n.axis.? == axis) return i;
        child = i;
    }
    return null;
}
fn extent(nodes: []const Node, index: usize, axis: Axis, sizes: anytype) u32 {
    const n = nodes[index];
    if (n.kind == .pane) return sizes.extent(n.pane.?, axis);
    const one = extent(nodes, n.first.?, axis, sizes);
    const two = extent(nodes, n.second.?, axis, sizes);
    return if (n.axis.? == axis) one + 1 + two else @max(one, two);
}
fn minExtent(nodes: []const Node, index: usize, axis: Axis) u32 {
    const n = nodes[index];
    if (n.kind == .pane) return 1;
    const one = minExtent(nodes, n.first.?, axis);
    const two = minExtent(nodes, n.second.?, axis);
    return if (n.axis.? == axis) one + 1 + two else @max(one, two);
}
test "nested topology edits, collapse, empty window and allocation rollback" {
    const a = std.testing.allocator;
    const initial = [_]Node{.{ .kind = .pane, .pane = "p0" }};
    const split = try edit(a, &initial, "p0", .{ .kind = .pane, .pane = "p1", .axis = .cols });
    defer a.free(split);
    const nested = try edit(a, split, "p1", .{ .kind = .pane, .pane = "p2", .axis = .rows });
    defer a.free(nested);
    try std.testing.expect(valid(nested));
    try std.testing.expectEqual(@as(usize, 5), nested.len);
    const removed = try edit(a, nested, "p1", null);
    defer a.free(removed);
    try std.testing.expectEqualStrings("p2", removed[2].pane.?);
    const sole = try edit(a, removed, "p0", null);
    defer a.free(sole);
    const empty = try edit(a, sole, "p2", null);
    defer a.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    const swapped = try replace(a, nested, "p1", "p9");
    defer a.free(swapped);
    try std.testing.expectEqual(nested.len, swapped.len);
    try std.testing.expectEqualStrings("p9", swapped[3].pane.?);
    try std.testing.expectEqualStrings("p1", nested[3].pane.?);
    try std.testing.checkAllAllocationFailures(a, allocationEdit, .{});
}
fn allocationEdit(a: std.mem.Allocator) !void {
    const old = [_]Node{.{ .kind = .pane, .pane = "p0" }};
    const result = try edit(a, &old, "p0", .{ .kind = .pane, .pane = "p1", .axis = .cols });
    defer a.free(result);
    try std.testing.expect(valid(result));
}
const TestSizes = struct {
    each: u32,
    pub fn extent(self: TestSizes, _: []const u8, _: Axis) u32 {
        return self.each;
    }
};
test "firstShare keeps equal splits and a cell for each child" {
    const expectEqual = std.testing.expectEqual;
    for ([_]u32{ 0, 1, 2, 3, 79, 80, 65535 }) |avail| try expectEqual(avail - avail / 2, firstShare(null, avail));
    try expectEqual(@as(u32, 1), firstShare(1, 80));
    try expectEqual(@as(u32, 79), firstShare(9999, 80));
    try expectEqual(@as(u32, 20), firstShare(2500, 80));
}
test "moveDivider moves the nearest split on the axis and stops at the edges" {
    const expectEqual = std.testing.expectEqual;
    // p0 | (p1 over (p2 | p3)), each pane 10 cells each way.
    var nodes = [_]Node{
        .{ .kind = .split, .axis = .cols, .first = 1, .second = 2 },
        .{ .kind = .pane, .pane = "p0" },
        .{ .kind = .split, .axis = .rows, .first = 3, .second = 4 },
        .{ .kind = .pane, .pane = "p1" },
        .{ .kind = .split, .axis = .cols, .first = 5, .second = 6 },
        .{ .kind = .pane, .pane = "p2" },
        .{ .kind = .pane, .pane = "p3" },
    };
    try std.testing.expect(valid(&nodes));
    const sizes: TestSizes = .{ .each = 10 };
    // The divider moves with the direction, whichever side the pane is on.
    const right = moveDivider(&nodes, "p0", .cols, 2, sizes).?;
    try expectEqual(@as(usize, 0), right.split);
    try expectEqual(@as(u32, 2), right.moved);
    const avail = 10 + 21;
    try expectEqual(firstShare(null, avail) + 2, firstShare(right.ratio, avail));
    try expectEqual(@as(usize, 4), moveDivider(&nodes, "p3", .cols, 1, sizes).?.split);
    // p1 has no cols split of its own, so its ancestor's divider moves.
    try expectEqual(@as(usize, 0), moveDivider(&nodes, "p1", .cols, -1, sizes).?.split);
    try expectEqual(@as(usize, 2), moveDivider(&nodes, "p3", .rows, 1, sizes).?.split);
    // Clamped at the minimum of the subtree: p2 | p3 needs three columns.
    const far = moveDivider(&nodes, "p0", .cols, 1000, sizes).?;
    try expectEqual(avail - 3, firstShare(far.ratio, avail));
    try expectEqual(avail - 3 - firstShare(null, avail), far.moved);
    nodes[0].ratio = far.ratio;
    try std.testing.expect(valid(&nodes));
    try std.testing.expect(moveDivider(&nodes, "p0", .cols, 1, sizes) == null);
    const back = moveDivider(&nodes, "p0", .cols, -1000, sizes).?;
    try expectEqual(@as(u32, 1), firstShare(back.ratio, avail));
    // Back to equal is no ratio at all.
    nodes = .{
        .{ .kind = .split, .axis = .cols, .first = 1, .second = 2, .ratio = 6000 },
        .{ .kind = .pane, .pane = "p0" },
        .{ .kind = .pane, .pane = "p1" },
        nodes[3],
        nodes[4],
        nodes[5],
        nodes[6],
    };
    const even = moveDivider(nodes[0..3], "p0", .cols, -2, sizes).?;
    try expectEqual(@as(u32, 2), even.moved);
    try expectEqual(@as(u32, 10), firstShare(even.ratio, 20));
    try std.testing.expect(even.ratio == null);
    // No split on the axis, or a lone pane, moves nothing.
    const lone = [_]Node{.{ .kind = .pane, .pane = "p0" }};
    try std.testing.expect(moveDivider(&lone, "p0", .cols, 1, sizes) == null);
    try std.testing.expect(moveDivider(nodes[0..3], "p0", .rows, 1, sizes) == null);
    // Edits keep the ratios of the splits they leave alone.
    const edited = try edit(std.testing.allocator, nodes[0..3], "p1", .{ .kind = .pane, .pane = "p9", .axis = .rows });
    defer std.testing.allocator.free(edited);
    try expectEqual(@as(?u16, 6000), edited[0].ratio);
    try expectEqual(@as(?u16, null), edited[2].ratio);
    var bad = nodes;
    bad[0].ratio = 0;
    try std.testing.expect(!valid(bad[0..3]));
    bad[0].ratio = 10000;
    try std.testing.expect(!valid(bad[0..3]));
}
test "moveDivider never crosses the divider against the direction, past a minimum on either side" {
    const expectEqual = std.testing.expectEqual;
    // (p0 | p2) | p1: the first child needs three columns, and has one.
    const left = [_]Node{
        .{ .kind = .split, .axis = .cols, .first = 1, .second = 4, .ratio = 62 },
        .{ .kind = .split, .axis = .cols, .first = 2, .second = 3 },
        .{ .kind = .pane, .pane = "p0" },
        .{ .kind = .pane, .pane = "p2" },
        .{ .kind = .pane, .pane = "p1" },
    };
    const each: TestSizes = .{ .each = 53 };
    const avail = 53 + 1 + 53 + 53;
    try expectEqual(@as(u32, 1), firstShare(62, avail));
    try std.testing.expect(moveDivider(&left, "p1", .cols, -1, each) == null);
    // Toward the minimum is allowed, a cell at a time, and short of it too.
    const up = moveDivider(&left, "p1", .cols, 1, each).?;
    try expectEqual(@as(u32, 1), up.moved);
    try expectEqual(@as(u32, 2), firstShare(up.ratio, avail));
    // The mirror: p1 | (p0 | p2), the second child with one column of three.
    const right = [_]Node{
        .{ .kind = .split, .axis = .cols, .first = 1, .second = 2, .ratio = 9990 },
        .{ .kind = .pane, .pane = "p1" },
        .{ .kind = .split, .axis = .cols, .first = 3, .second = 4 },
        .{ .kind = .pane, .pane = "p0" },
        .{ .kind = .pane, .pane = "p2" },
    };
    try expectEqual(@as(u32, avail - 1), firstShare(9990, avail));
    try std.testing.expect(moveDivider(&right, "p1", .cols, 1, each) == null);
    const down = moveDivider(&right, "p1", .cols, -1, each).?;
    try expectEqual(@as(u32, 1), down.moved);
    try expectEqual(@as(u32, avail - 2), firstShare(down.ratio, avail));
    // Shrink: a tiny viewport puts both children under their minimums at once.
    const tiny: TestSizes = .{ .each = 1 };
    const small = [_]Node{
        .{ .kind = .split, .axis = .cols, .first = 1, .second = 4 },
        .{ .kind = .split, .axis = .cols, .first = 2, .second = 3 },
        .{ .kind = .pane, .pane = "p0" },
        .{ .kind = .pane, .pane = "p2" },
        .{ .kind = .split, .axis = .rows, .first = 5, .second = 6 },
        .{ .kind = .pane, .pane = "p1" },
        .{ .kind = .pane, .pane = "p3" },
    };
    // avail 4 fits the minimums 3 + 1 exactly; equal gives the first child 2.
    try expectEqual(@as(u32, 2), firstShare(null, 4));
    const fits = moveDivider(&small, "p1", .cols, -1, tiny);
    try std.testing.expect(fits == null);
    const grows = moveDivider(&small, "p1", .cols, 5, tiny).?;
    try expectEqual(@as(u32, 1), grows.moved);
    try expectEqual(@as(u32, 3), firstShare(grows.ratio, 4));
}
test "moveDivider reports what the ratio reads back, past the ratio's resolution" {
    const expectEqual = std.testing.expectEqual;
    const nodes = [_]Node{
        .{ .kind = .split, .axis = .cols, .first = 1, .second = 2 },
        .{ .kind = .pane, .pane = "p0" },
        .{ .kind = .pane, .pane = "p1" },
    };
    const huge: TestSizes = .{ .each = 10000 };
    // A cell is less than 1/10000 of 20000, so one cell up moves nothing.
    try std.testing.expect(moveDivider(&nodes, "p0", .cols, 1, huge) == null);
    // Down, the floor lands on the next ratio it can name; moved says so.
    const back = moveDivider(&nodes, "p0", .cols, -1, huge).?;
    try expectEqual(@as(u32, 2), back.moved);
    try expectEqual(@as(u32, 9998), firstShare(back.ratio, 20000));
    const two = moveDivider(&nodes, "p0", .cols, 2, huge).?;
    try expectEqual(@as(u32, 2), two.moved);
    try expectEqual(@as(?u16, 5001), two.ratio);
    try expectEqual(@as(u32, 10002), firstShare(two.ratio, 20000));
    // Up to 10000 cells every cell has a ratio.
    const fine: TestSizes = .{ .each = 5000 };
    for ([_]i64{ -3, -1, 1, 7 }) |delta| {
        const m = moveDivider(&nodes, "p0", .cols, delta, fine).?;
        try expectEqual(@as(u32, @intCast(@abs(delta))), m.moved);
        try expectEqual(@as(i64, 5000) + delta, @as(i64, firstShare(m.ratio, 10000)));
    }
}
test "a split that would leave a child below its minimum clamps that ratio" {
    const a = std.testing.allocator;
    const expectEqual = std.testing.expectEqual;
    const sizes: TestSizes = .{ .each = 40 };
    const old = [_]Node{
        .{ .kind = .split, .axis = .cols, .first = 1, .second = 2, .ratio = 125 },
        .{ .kind = .pane, .pane = "p0" },
        .{ .kind = .pane, .pane = "p1" },
    };
    try expectEqual(@as(u32, 1), firstShare(125, 80));
    // p0 has one column, and two panes need three: they come from p1 alone.
    const across = try editSplit(a, &old, "p0", .{ .kind = .pane, .pane = "p2", .axis = .cols }, sizes);
    defer a.free(across);
    try expectEqual(@as(u32, 3), firstShare(across[0].ratio, 80));
    // Down it needs no more columns, and p1 has plenty: the ratio stays.
    const down = try editSplit(a, &old, "p0", .{ .kind = .pane, .pane = "p2", .axis = .rows }, sizes);
    defer a.free(down);
    try expectEqual(@as(?u16, 125), down[0].ratio);
    const beside = try editSplit(a, &old, "p1", .{ .kind = .pane, .pane = "p2", .axis = .cols }, sizes);
    defer a.free(beside);
    try expectEqual(@as(?u16, 125), beside[0].ratio);
    // The mirror: the second child short of columns takes them from the first.
    var mirror = old;
    mirror[0].ratio = 9875;
    try expectEqual(@as(u32, 79), firstShare(9875, 80));
    const second = try editSplit(a, &mirror, "p1", .{ .kind = .pane, .pane = "p2", .axis = .cols }, sizes);
    defer a.free(second);
    try expectEqual(@as(u32, 77), firstShare(second[0].ratio, 80));
    // Only the ancestors that are short: an outer ratio with room stays.
    const nested = [_]Node{
        .{ .kind = .split, .axis = .cols, .first = 1, .second = 4, .ratio = 7000 },
        .{ .kind = .split, .axis = .cols, .first = 2, .second = 3, .ratio = 100 },
        .{ .kind = .pane, .pane = "p0" },
        .{ .kind = .pane, .pane = "p1" },
        .{ .kind = .pane, .pane = "p2" },
    };
    const inner = try editSplit(a, &nested, "p0", .{ .kind = .pane, .pane = "p3", .axis = .cols }, sizes);
    defer a.free(inner);
    try std.testing.expect(valid(inner));
    try expectEqual(@as(?u16, 7000), inner[0].ratio);
    // The inner split divides the 84 columns the outer ratio gives it.
    try expectEqual(@as(u32, 85), firstShare(7000, 40 * 3 + 1));
    try expectEqual(@as(u32, 3), firstShare(inner[1].ratio, 84));
    // A viewport too small for both minimums goes back to equal shares.
    const tiny = try editSplit(a, &old, "p0", .{ .kind = .pane, .pane = "p2", .axis = .cols }, TestSizes{ .each = 1 });
    defer a.free(tiny);
    try expectEqual(@as(?u16, null), tiny[0].ratio);
    // A layout nobody resized stays without ratios, clipped or not.
    var equal = old;
    equal[0].ratio = null;
    const plain = try editSplit(a, &equal, "p0", .{ .kind = .pane, .pane = "p2", .axis = .cols }, TestSizes{ .each = 1 });
    defer a.free(plain);
    try expectEqual(@as(?u16, null), plain[0].ratio);
}
/// Each pane's own size, the same on both axes.
const PaneTestSizes = struct {
    names: []const []const u8,
    cells: []const u32,
    pub fn extent(self: PaneTestSizes, pane: []const u8, _: Axis) u32 {
        for (self.names, self.cells) |name, n| if (std.mem.eql(u8, name, pane)) return n;
        unreachable;
    }
};
/// Lays the tree out top-down on `cells` columns, as a client draws it.
fn drawCols(nodes: []const Node, index: usize, cells: u32, names: []const []const u8, out: []u32) void {
    const n = nodes[index];
    if (n.kind == .pane) {
        for (names, 0..) |name, k| if (std.mem.eql(u8, name, n.pane.?)) {
            out[k] = cells;
        };
        return;
    }
    const avail = cells -| 1;
    const share = firstShare(n.ratio, avail);
    drawCols(nodes, n.first.?, share, names, out);
    drawCols(nodes, n.second.?, avail - share, names, out);
}
test "a split clamps an ancestor without clipping panes on its other side" {
    const a = std.testing.allocator;
    const expectEqual = std.testing.expectEqual;
    // p0 | (pa | (pb | pc)) at 161 columns, ratios 62 and 9807.
    const old = [_]Node{
        .{ .kind = .split, .axis = .cols, .first = 1, .second = 2, .ratio = 62 },
        .{ .kind = .pane, .pane = "p0" },
        .{ .kind = .split, .axis = .cols, .first = 3, .second = 4, .ratio = 9807 },
        .{ .kind = .pane, .pane = "pa" },
        .{ .kind = .split, .axis = .cols, .first = 5, .second = 6 },
        .{ .kind = .pane, .pane = "pb" },
        .{ .kind = .pane, .pane = "pc" },
    };
    const names = [_][]const u8{ "p0", "pa", "pb", "pc", "pn" };
    var drawn: [names.len]u32 = undefined;
    drawCols(&old, 0, 161, names[0..4], drawn[0..4]);
    try std.testing.expectEqualSlices(u32, &.{ 1, 155, 1, 1 }, drawn[0..4]);
    const sizes: PaneTestSizes = .{ .names = names[0..4], .cells = drawn[0..4] };
    const split = try editSplit(a, &old, "p0", .{ .kind = .pane, .pane = "pn", .axis = .cols }, sizes);
    defer a.free(split);
    try std.testing.expect(valid(split));
    try expectEqual(@as(?u16, 9807), split[4].ratio);
    drawCols(split, 0, 161, &names, &drawn);
    // p0 and the new pane take their column each from pa; pb and pc keep theirs.
    try std.testing.expectEqualSlices(u32, &.{ 1, 153, 1, 1, 1 }, &drawn);
}
test "a split keeps the ratio of an ancestor already clipped on its other side" {
    const a = std.testing.allocator;
    const expectEqual = std.testing.expectEqual;
    // p1 | (p0 | p2): the second child needs three columns, and has one.
    const old = [_]Node{
        .{ .kind = .split, .axis = .cols, .first = 1, .second = 2, .ratio = 9990 },
        .{ .kind = .pane, .pane = "p1" },
        .{ .kind = .split, .axis = .cols, .first = 3, .second = 4 },
        .{ .kind = .pane, .pane = "p0" },
        .{ .kind = .pane, .pane = "p2" },
    };
    const each: TestSizes = .{ .each = 53 };
    try expectEqual(@as(u32, 159), firstShare(9990, 160));
    // p1 has room for two panes: the clipped side is not this split's to fix.
    const across = try editSplit(a, &old, "p1", .{ .kind = .pane, .pane = "p3", .axis = .cols }, each);
    defer a.free(across);
    try expectEqual(@as(?u16, 9990), across[0].ratio);
    // Splitting the clipped side itself, down, raises no column minimum.
    const down = try editSplit(a, &old, "p0", .{ .kind = .pane, .pane = "p3", .axis = .rows }, each);
    defer a.free(down);
    try expectEqual(@as(?u16, 9990), down[0].ratio);
    // Across, it does: the clipped side takes the five columns it now needs.
    const more = try editSplit(a, &old, "p0", .{ .kind = .pane, .pane = "p3", .axis = .cols }, each);
    defer a.free(more);
    try expectEqual(@as(u32, 155), firstShare(more[0].ratio, 160));
}
