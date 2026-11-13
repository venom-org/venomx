//! Principal events through a real Product and dispatcher (see
//! `principal_events.zig`). Lives with the dispatcher tests, which build with
//! the full terminal modules.
const std = @import("std");
const proto = @import("proto");
const g = proto.grants;
const Emitter = @import("principal_events.zig").Emitter;

const testing = std.testing;
const chrome_tests = @import("chrome_tests.zig");
const Daemon = chrome_tests.Daemon;
const ta = testing.allocator;

fn daemon() !*Daemon {
    const d = try Daemon.create();
    errdefer d.destroy();
    return d;
}
fn install(d: *Daemon, e: *Emitter) void {
    e.* = .{ .events = &d.events, .registry = &d.registry };
    d.registry.observer = e.observer();
}
/// The raw NDJSON a non-following `events` call writes for `conn`.
fn subscribe(d: *Daemon, conn: *proto.Connection) ![]u8 {
    conn.output.clearRetainingCapacity();
    conn.sent = 0;
    const line = try std.fmt.allocPrint(ta, "{{\"id\":900,\"verb\":\"events\",\"params\":{{\"types\":[\"principal.*\"],\"after\":\"{s}:0\",\"follow\":false}}}}", .{d.events.source});
    defer ta.free(line);
    try d.dispatcher.message(conn, .{ .ndjson = line });
    return ta.dupe(u8, conn.output.items);
}
fn count(hay: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, hay, needle);
}
fn entriesContain(d: *Daemon, needle: []const u8) bool {
    for (d.events.entries.items[d.events.head..]) |e| if (std.mem.indexOf(u8, e.bytes, needle) != null) return true;
    return false;
}

test "principal.created carries kind, parent, grants and expires, and no token or label" {
    const d = try daemon();
    defer d.destroy();
    var em: Emitter = undefined;
    install(d, &em);
    defer em.deinit();
    const gs = [_]g.Grant{.{ .right = .read, .scope = "*" }};
    const issued = try d.registry.issueChild(.{ .principal = g.owner }, .{ .kind = .token, .grants = &gs, .label = "my-secret-label" }, g.nowSeconds());
    defer ta.free(issued.token);
    var owner = d.connection(g.owner);
    defer owner.deinit();
    const out = try subscribe(d, &owner);
    defer ta.free(out);
    try testing.expectEqual(@as(usize, 1), count(out, "\"type\":\"principal.created\""));
    for ([_][]const u8{ "\"kind\":\"token\"", "\"parent\":\"owner\"", "\"right\":\"read\"", "\"scope\":\"*\"", "\"expires\":\"" }) |want| {
        if (std.mem.indexOf(u8, out, want) == null) std.debug.print("missing {s} in {s}\n", .{ want, out });
        try testing.expect(std.mem.indexOf(u8, out, want) != null);
    }
    try testing.expect(!entriesContain(d, issued.token));
    try testing.expect(!entriesContain(d, "vnt1"));
    try testing.expect(!entriesContain(d, "my-secret-label"));
}

test "principal.denied from the gate: owner and the principal see it, a sibling does not; no params or token" {
    const d = try daemon();
    defer d.destroy();
    var em: Emitter = undefined;
    install(d, &em);
    defer em.deinit();
    const ro = [_]g.Grant{.{ .right = .read, .scope = "*" }};
    const a1 = try d.principal(&ro, null);
    const a2 = try d.principal(&ro, null);
    var agent = d.connection(a1);
    defer agent.deinit();
    var sibling = d.connection(a2);
    defer sibling.deinit();
    var owner = d.connection(g.owner);
    defer owner.deinit();
    {
        var r = try d.call(&agent, "pane.send", "{\"pane\":\"p1\",\"text\":\"TOPSECRET-PARAMS\"}");
        defer r.deinit();
        try testing.expectEqualStrings("denied.write", r.value.object.get("error").?.object.get("code").?.string);
    }
    try testing.expect(entriesContain(d, "\"type\":\"principal.denied\""));
    try testing.expect(entriesContain(d, "\"verb\":\"pane.send\""));
    try testing.expect(entriesContain(d, "\"right\":\"write\""));
    try testing.expect(!entriesContain(d, "TOPSECRET-PARAMS"));
    try testing.expect(!entriesContain(d, "vnt1"));
    var want: [24]u8 = undefined;
    const needle = try std.fmt.allocPrint(ta, "principal:{s}", .{g.name(a1, &want)});
    defer ta.free(needle);
    const o = try subscribe(d, &owner);
    defer ta.free(o);
    try testing.expectEqual(@as(usize, 1), count(o, "\"type\":\"principal.denied\""));
    const logged = for (d.events.entries.items[d.events.head..]) |e| {
        if (std.mem.eql(u8, e.type, "principal.denied")) break e.resource;
    } else "";
    try testing.expectEqualStrings(needle, logged);
    const me = try subscribe(d, &agent);
    defer ta.free(me);
    try testing.expectEqual(@as(usize, 1), count(me, "\"type\":\"principal.denied\""));
    const sib = try subscribe(d, &sibling);
    defer ta.free(sib);
    try testing.expectEqual(@as(usize, 0), count(sib, "principal.denied"));
    // Only its own record, never the other agent's.
    try testing.expectEqual(@as(usize, 1), count(sib, "principal.created"));
}

test "an unknown caller's denied verb emits no event" {
    const d = try daemon();
    defer d.destroy();
    var em: Emitter = undefined;
    install(d, &em);
    defer em.deinit();
    const before = d.events.high;
    var anon = d.connection(g.unknown);
    defer anon.deinit();
    {
        var r = try d.call(&anon, "pane.send", "{\"pane\":\"p1\",\"text\":\"x\"}");
        defer r.deinit();
        try testing.expect(r.value.object.get("error") != null);
    }
    try testing.expectEqual(before, d.events.high);
}

test "principal.revoked names the reason and cascade; descendants get no event of their own" {
    const d = try daemon();
    defer d.destroy();
    var em: Emitter = undefined;
    install(d, &em);
    defer em.deinit();
    const gs = [_]g.Grant{ .{ .right = .read, .scope = "*" }, .{ .right = .spawn, .scope = "*" } };
    const parent = try d.principal(&gs, null);
    const child_issue = try d.registry.issueChild(.{ .principal = parent }, .{ .kind = .token, .grants = &.{.{ .right = .read, .scope = "*" }} }, g.nowSeconds());
    defer ta.free(child_issue.token);
    try d.registry.revoke(.{ .principal = g.owner }, parent, g.nowSeconds());
    var owner = d.connection(g.owner);
    defer owner.deinit();
    const out = try subscribe(d, &owner);
    defer ta.free(out);
    try testing.expectEqual(@as(usize, 1), count(out, "\"type\":\"principal.revoked\""));
    try testing.expect(std.mem.indexOf(u8, out, "\"reason\":\"revoked\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"cascade\":1") != null);
    try testing.expect(!entriesContain(d, child_issue.token));
}

test "a pane principal is announced by its spawn, not by the registry observer" {
    const d = try daemon();
    defer d.destroy();
    var em: Emitter = undefined;
    install(d, &em);
    defer em.deinit();
    const before = d.events.high;
    const issued = try d.registry.issueChild(.{ .principal = g.owner }, .{ .kind = .pane, .pane = "p3" }, g.nowSeconds());
    defer ta.free(issued.token);
    try testing.expectEqual(before, d.events.high);
    // A rolled-back spawn silences the revocation of what was never announced.
    em.silence(issued.principal);
    try d.registry.revoke(.{ .principal = g.owner }, issued.principal, g.nowSeconds());
    try testing.expectEqual(before, d.events.high);
    var batch = try @import("product.zig").Batch.init(&d.events);
    defer batch.deinit();
    const second = try d.registry.issueChild(.{ .principal = g.owner }, .{ .kind = .pane, .pane = "p4" }, g.nowSeconds());
    defer ta.free(second.token);
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    try @import("principal_events.zig").appendCreated(&batch, arena.allocator(), &d.registry, second.principal);
    try batch.reserve();
    batch.commit();
    try testing.expect(entriesContain(d, "\"pane\":\"p4\""));
    try testing.expect(entriesContain(d, "\"kind\":\"pane\""));
}

fn denyWith(d: *Daemon, who: g.Id, verb: []const u8, code: []const u8, resource: ?[]const u8) void {
    d.registry.denied(.{ .principal = who }, verb, .write, code, resource);
}
fn deniedCount(d: *Daemon) usize {
    var n: usize = 0;
    for (d.events.entries.items[d.events.head..]) |e| {
        if (std.mem.eql(u8, e.type, "principal.denied")) n += 1;
    }
    return n;
}

test "denied.resource is copied only when short and valid, else its kind, else nothing" {
    const d = try daemon();
    defer d.destroy();
    var em: Emitter = undefined;
    install(d, &em);
    defer em.deinit();
    em.now_ms = 0;
    const who = try d.principal(&.{.{ .right = .read, .scope = "*" }}, null);
    const huge = try ta.alloc(u8, 1 << 20);
    defer ta.free(huge);
    @memset(huge, 'x');
    @memcpy(huge[0..5], "pane:");
    const cases = [_]struct { name: []const u8, resource: []const u8, want: ?[]const u8 }{
        .{ .name = "valid", .resource = "pane:p1", .want = "pane:p1" },
        .{ .name = "1 MiB", .resource = huge, .want = "pane" },
        .{ .name = "control", .resource = "pane:p1\x01", .want = "pane" },
        .{ .name = "C1", .resource = "pane:p\xc2\x85", .want = "pane" },
        .{ .name = "no kind", .resource = "garbage", .want = null },
        .{ .name = "bad kind", .resource = "Pane:p1", .want = null },
        .{ .name = "path", .resource = "file:/a/b.c-d_e", .want = "file:/a/b.c-d_e" },
        .{ .name = "space", .resource = "pane:p 1", .want = "pane" },
        .{ .name = "bidi override", .resource = "pane:p\xe2\x80\xae1", .want = "pane" },
        .{ .name = "zero-width joiner", .resource = "pane:p\xe2\x80\x8d1", .want = "pane" },
        .{ .name = "quote", .resource = "pane:p\"1", .want = "pane" },
    };
    for (cases, 0..) |case, i| {
        em.now_ms = @as(i64, @intCast(i)) * 2000;
        const before = d.events.entries.items.len;
        denyWith(d, who, "pane.send", "denied.write", case.resource);
        try testing.expectEqual(before + 1, d.events.entries.items.len);
        const bytes = d.events.entries.items[d.events.entries.items.len - 1].bytes;
        if (case.want) |w| {
            const needle = try std.fmt.allocPrint(ta, "\"resource\":\"{s}\"", .{w});
            defer ta.free(needle);
            if (std.mem.indexOf(u8, bytes, needle) == null) std.debug.print("{s}: {s}\n", .{ case.name, bytes });
            try testing.expect(std.mem.indexOf(u8, bytes, needle) != null);
        } else try testing.expect(std.mem.indexOf(u8, bytes, "\"resource\"") == null);
        try testing.expect(bytes.len < 512);
    }
}

test "principal.denied is coalesced per principal, verb and right per second" {
    const d = try daemon();
    defer d.destroy();
    var em: Emitter = undefined;
    install(d, &em);
    defer em.deinit();
    const who = try d.principal(&.{.{ .right = .read, .scope = "*" }}, null);
    const other = try d.principal(&.{.{ .right = .read, .scope = "*" }}, null);
    em.now_ms = 10_000;
    for (0..100) |_| denyWith(d, who, "pane.send", "denied.write", "pane:p1");
    try testing.expectEqual(@as(usize, 1), deniedCount(d));
    // Another verb or principal has its own window.
    denyWith(d, who, "pane.kill", "denied.write", null);
    denyWith(d, other, "pane.send", "denied.write", null);
    try testing.expectEqual(@as(usize, 3), deniedCount(d));
    em.now_ms = 10_999;
    denyWith(d, who, "pane.send", "denied.write", null);
    try testing.expectEqual(@as(usize, 3), deniedCount(d));
    em.now_ms = 11_000;
    denyWith(d, who, "pane.send", "denied.write", null);
    try testing.expectEqual(@as(usize, 4), deniedCount(d));
    // A revoked principal's windows are forgotten.
    try d.registry.revoke(.{ .principal = g.owner }, other, g.nowSeconds());
    try testing.expect(em.last_denied.count() <= 2);
}

test "the coalescing table stays bounded under a flood of principals" {
    const d = try daemon();
    defer d.destroy();
    var em: Emitter = undefined;
    install(d, &em);
    defer em.deinit();
    em.now_ms = 0;
    for (0..Emitter.max_tracked + 50) |i| {
        var name: [16]u8 = undefined;
        const verb = std.fmt.bufPrint(&name, "pane.v{d}", .{i}) catch unreachable;
        denyWith(d, g.owner + 2, verb, "denied.write", null);
    }
    try testing.expect(em.last_denied.count() <= Emitter.max_tracked);
}

fn manyPrincipals(d: *Daemon, n: usize) ![]g.Id {
    const ids = try ta.alloc(g.Id, n);
    for (ids) |*id| id.* = try d.principal(&.{.{ .right = .read, .scope = "*" }}, null);
    return ids;
}
fn heldBy(em: *const Emitter, root: g.Id) usize {
    var n: usize = 0;
    var it = em.last_denied.valueIterator();
    while (it.next()) |w| {
        if (w.root == root) n += 1;
    }
    return n;
}

const spawner_grants = [_]g.Grant{ .{ .right = .read, .scope = "*" }, .{ .right = .spawn, .scope = "*" } };
fn child(d: *Daemon, parent: g.Id) !g.Id {
    const issued = try d.registry.issueChild(.{ .principal = parent }, .{ .kind = .token, .grants = &spawner_grants }, g.nowSeconds());
    ta.free(issued.token);
    return issued.principal;
}
fn verbName(buf: []u8, i: usize) []const u8 {
    return std.fmt.bufPrint(buf, "pane.v{d}", .{i}) catch unreachable;
}
/// `who` holds `n` keys at `em.now_ms`, a few at a time (one bucket's burst).
fn holdKeys(d: *Daemon, em: *Emitter, who: g.Id, n: usize) void {
    var verb: [16]u8 = undefined;
    for (0..n) |i| {
        em.buckets.clearRetainingCapacity();
        denyWith(d, who, verbName(&verb, i), "denied.write", null);
    }
}

test "a tree's keys are bounded by its budget and a principal's further keys fold into one window" {
    const d = try daemon();
    defer d.destroy();
    var em: Emitter = undefined;
    install(d, &em);
    defer em.deinit();
    em.now_ms = 0;
    const top = try d.principal(&spawner_grants, null);
    // Ten children, four keys each (one burst): the first 32 keys are held.
    for (0..10) |_| {
        holdKeys(d, &em, try child(d, top), 4);
    }
    // 32 held, then two fresh children's first keys, and one fold window.
    try testing.expectEqual(@as(usize, Emitter.per_root_keys + 3), deniedCount(d));
    try testing.expectEqual(@as(usize, Emitter.per_root_keys + 3), heldBy(&em, top));
}

/// Nine children of `top` at t=0: 32 keys held, a tenth key folded (child 8's
/// second), and child 9 with one key whose second key is held back.
fn busyTree(d: *Daemon, em: *Emitter, top: g.Id) ![2]g.Id {
    for (0..8) |_| holdKeys(d, em, try child(d, top), 4);
    const c8 = try child(d, top);
    holdKeys(d, em, c8, 2);
    const c9 = try child(d, top);
    holdKeys(d, em, c9, 2);
    return .{ c8, c9 };
}

test "a tree root's first denial is not folded into its children's window" {
    const d = try daemon();
    defer d.destroy();
    var em: Emitter = undefined;
    install(d, &em);
    defer em.deinit();
    em.now_ms = 0;
    const top = try d.principal(&spawner_grants, null);
    _ = try busyTree(d, &em, top);
    const before = deniedCount(d);
    denyWith(d, top, "pane.send", "denied.write", null);
    try testing.expectEqual(before + 1, deniedCount(d));
}

test "a key folded into a busy window is counted on the principal's next event" {
    const d = try daemon();
    defer d.destroy();
    var em: Emitter = undefined;
    install(d, &em);
    defer em.deinit();
    em.now_ms = 0;
    const top = try d.principal(&spawner_grants, null);
    const kids = try busyTree(d, &em, top);
    try testing.expect(!entriesContain(d, "suppressed"));
    em.now_ms = Emitter.window_ms;
    denyWith(d, kids[1], "pane.later", "denied.write", null);
    try testing.expect(entriesContain(d, "\"suppressed\":1"));
}

test "retries of one folded verb are coalesced like retries of a known key" {
    const d = try daemon();
    defer d.destroy();
    var em: Emitter = undefined;
    install(d, &em);
    defer em.deinit();
    em.now_ms = 0;
    const top = try d.principal(&spawner_grants, null);
    const kids = try busyTree(d, &em, top);
    var verb: [16]u8 = undefined;
    // Child 9's second key was held back once; its retries add nothing.
    for (0..500) |_| denyWith(d, kids[1], verbName(&verb, 1), "denied.write", null);
    try testing.expectEqual(@as(u32, 1), em.held.get(kids[1]).?.suppressed);
    // Another verb is another denial held back, and its retries merge too.
    for (0..10) |_| denyWith(d, kids[1], "pane.other", "denied.write", null);
    try testing.expectEqual(@as(u32, 2), em.held.get(kids[1]).?.suppressed);
    // Child 8's second key went out through the fold window: its retries merge,
    // whatever its sibling did since.
    const before = deniedCount(d);
    for (0..100) |_| denyWith(d, kids[0], verbName(&verb, 1), "denied.write", null);
    try testing.expectEqual(before, deniedCount(d));
    try testing.expectEqual(@as(u32, 0), em.held.get(kids[0]).?.suppressed);
    em.now_ms = Emitter.window_ms;
    denyWith(d, kids[1], "pane.later", "denied.write", null);
    try testing.expect(entriesContain(d, "\"suppressed\":2"));
    try testing.expectEqual(@as(u64, 0), em.dropped);
}

test "siblings denied the same folded verb in one window are each counted, never swallowed" {
    const d = try daemon();
    defer d.destroy();
    var em: Emitter = undefined;
    install(d, &em);
    defer em.deinit();
    em.now_ms = 0;
    const top = try d.principal(&spawner_grants, null);
    const kids = try busyTree(d, &em, top);
    // Child 8's v1 went out through the fold window. Its sibling asks the same
    // verb: not published, but counted against the sibling alone.
    denyWith(d, kids[1], "pane.v1", "denied.write", null);
    denyWith(d, kids[1], "pane.v1", "denied.write", null);
    try testing.expectEqual(@as(u32, 1), em.held.get(kids[1]).?.suppressed);
    try testing.expectEqual(@as(u32, 0), em.held.get(kids[0]).?.suppressed);
    // The sibling's own next event reports its count, and only its own.
    em.now_ms = Emitter.window_ms;
    denyWith(d, kids[1], "pane.later", "denied.write", null);
    const last = d.events.entries.items[d.events.entries.items.len - 1].bytes;
    try testing.expect(std.mem.indexOf(u8, last, "\"suppressed\":1") != null);
    try expectCounts(&em);
}

test "a folded denial whose bucket was pruned is held back, not dropped" {
    const d = try daemon();
    defer d.destroy();
    var em: Emitter = undefined;
    install(d, &em);
    defer em.deinit();
    em.now_ms = 0;
    const top = try d.principal(&spawner_grants, null);
    _ = try busyTree(d, &em, top);
    const late = try child(d, top);
    denyWith(d, late, "pane.v0", "denied.write", null);
    // Half a second refills its bucket, and pruning forgets it (as
    // `pruneBuckets` does under pressure) while its key is still live.
    em.now_ms = 500;
    try testing.expect(em.buckets.remove(top));
    denyWith(d, late, "pane.x", "denied.write", null);
    try testing.expectEqual(@as(u64, 0), em.dropped);
    try testing.expectEqual(@as(u32, 0), em.drop_warnings);
    try testing.expectEqual(@as(u32, 1), em.held.get(late).?.suppressed);
    em.now_ms = Emitter.window_ms;
    const before = deniedCount(d);
    denyWith(d, late, "pane.later", "denied.write", null);
    try testing.expectEqual(before + 1, deniedCount(d));
    const last = d.events.entries.items[d.events.entries.items.len - 1].bytes;
    try testing.expect(std.mem.indexOf(u8, last, "\"suppressed\":1") != null);
}

test "a full held-back table loses counts and warns whenever the dropped count crosses a power of two" {
    const d = try daemon();
    defer d.destroy();
    var em: Emitter = undefined;
    install(d, &em);
    defer em.deinit();
    em.now_ms = 0;
    const ids = try manyPrincipals(d, Emitter.max_tracked);
    defer ta.free(ids);
    // Every principal owes 37 and its tree's bucket is empty: none can be pruned.
    for (ids) |id| {
        try em.held.put(em.events.gpa, id, .{ .suppressed = 37 });
        try em.buckets.put(em.events.gpa, id, .{ .milli = 0, .at = 0 });
    }
    em.dropped = 6;
    const a = try d.principal(&.{.{ .right = .read, .scope = "*" }}, null);
    try em.buckets.put(em.events.gpa, a, .{ .milli = 0, .at = 0 });
    // 6 -> 7 crosses nothing; 7 -> 8 crosses 8; 8 -> 9 nothing.
    denyWith(d, a, "pane.send", "denied.write", null);
    try testing.expectEqual(@as(u64, 7), em.dropped);
    try testing.expectEqual(@as(u32, 0), em.drop_warnings);
    denyWith(d, a, "pane.send2", "denied.write", null);
    try testing.expectEqual(@as(u64, 8), em.dropped);
    try testing.expectEqual(@as(u32, 1), em.drop_warnings);
    denyWith(d, a, "pane.send3", "denied.write", null);
    try testing.expectEqual(@as(u64, 9), em.dropped);
    try testing.expectEqual(@as(u32, 1), em.drop_warnings);
    try testing.expectEqual(@as(usize, 0), em.last_denied.count());
}

test "expired windows do not count against a long-lived tree" {
    const d = try daemon();
    defer d.destroy();
    var em: Emitter = undefined;
    install(d, &em);
    defer em.deinit();
    em.now_ms = 0;
    const top = try d.principal(&spawner_grants, null);
    for (0..8) |_| holdKeys(d, &em, try child(d, top), 4);
    try testing.expectEqual(@as(usize, Emitter.per_root_keys), deniedCount(d));
    for ([_]i64{ 5000, 5300 }) |t| {
        em.now_ms = t;
        const before = deniedCount(d);
        const fresh = try child(d, top);
        denyWith(d, fresh, "pane.send", "denied.write", null);
        try testing.expectEqual(before + 1, deniedCount(d));
        // A second key of the same principal is not folded either: nothing live is held.
        denyWith(d, fresh, "pane.kill", "denied.write", null);
        try testing.expectEqual(before + 2, deniedCount(d));
    }
}

test "the tree root is found at any depth" {
    const d = try daemon();
    defer d.destroy();
    var em: Emitter = undefined;
    install(d, &em);
    defer em.deinit();
    const top = try d.principal(&spawner_grants, null);
    var cur = top;
    for (0..100) |_| cur = try child(d, cur);
    try testing.expectEqual(top, em.rootOf(cur));
    try testing.expectEqual(top, em.rootOf(top));
}

test "a full table admits a principal with no key even when its own tree ties for the most" {
    const d = try daemon();
    defer d.destroy();
    var em: Emitter = undefined;
    install(d, &em);
    defer em.deinit();
    em.now_ms = 0;
    const a = try d.principal(&spawner_grants, null);
    const b = try d.principal(&spawner_grants, null);
    holdKeys(d, &em, a, Emitter.per_root_keys);
    holdKeys(d, &em, b, Emitter.per_root_keys);
    const ids = try manyPrincipals(d, Emitter.max_tracked - 2 * Emitter.per_root_keys);
    defer ta.free(ids);
    for (ids) |id| denyWith(d, id, "pane.send", "denied.write", null);
    try testing.expectEqual(@as(usize, Emitter.max_tracked), em.last_denied.count());
    // Tie: the other tree gives way.
    const kid = try child(d, a);
    denyWith(d, kid, "pane.send", "denied.write", null);
    try testing.expectEqual(@as(usize, 1), heldBy(&em, a) - Emitter.per_root_keys);
    try testing.expectEqual(@as(usize, Emitter.per_root_keys - 1), heldBy(&em, b));
    // Now its own tree is the largest: a sibling's key goes.
    const kid2 = try child(d, a);
    denyWith(d, kid2, "pane.send", "denied.write", null);
    try testing.expectEqual(@as(usize, Emitter.per_root_keys + 1), heldBy(&em, a));
    try testing.expectEqual(@as(u64, 0), em.dropped);
}

test "a fresh principal's first denial is published while another tree fills the table" {
    const d = try daemon();
    defer d.destroy();
    var em: Emitter = undefined;
    install(d, &em);
    defer em.deinit();
    em.now_ms = 0;
    const ids = try manyPrincipals(d, Emitter.max_tracked);
    defer ta.free(ids);
    for (ids) |id| denyWith(d, id, "pane.send", "denied.write", null);
    try testing.expectEqual(@as(usize, Emitter.max_tracked), em.last_denied.count());
    const fresh = try d.principal(&.{.{ .right = .read, .scope = "*" }}, null);
    const before = deniedCount(d);
    denyWith(d, fresh, "pane.send", "denied.write", null);
    try testing.expectEqual(before + 1, deniedCount(d));
    try testing.expect(em.last_denied.count() <= Emitter.max_tracked);
    try testing.expectEqual(@as(usize, 1), heldBy(&em, fresh));
    try testing.expectEqual(@as(u64, 0), em.dropped);
}

test "a full table evicts from the largest holder, and a holder at the top is dropped and counted" {
    const d = try daemon();
    defer d.destroy();
    var em: Emitter = undefined;
    install(d, &em);
    defer em.deinit();
    em.now_ms = 0;
    const ids = try manyPrincipals(d, Emitter.max_tracked - Emitter.per_root_keys);
    defer ta.free(ids);
    // The big holder: a principal with per_root_keys keys, three at a time.
    const big = try d.principal(&.{.{ .right = .read, .scope = "*" }}, null);
    var verb: [16]u8 = undefined;
    var i: usize = 0;
    while (i < Emitter.per_root_keys) : (i += 1) {
        em.now_ms = @as(i64, @intCast(i / 2)) * 10;
        em.buckets.clearRetainingCapacity();
        denyWith(d, big, std.fmt.bufPrint(&verb, "v{d}", .{i}) catch unreachable, "denied.write", null);
    }
    em.now_ms = 0;
    for (ids) |id| denyWith(d, id, "pane.send", "denied.write", null);
    try testing.expectEqual(@as(usize, Emitter.max_tracked), em.last_denied.count());
    try testing.expectEqual(@as(usize, Emitter.per_root_keys), heldBy(&em, big));
    const fresh = try d.principal(&.{.{ .right = .read, .scope = "*" }}, null);
    denyWith(d, fresh, "pane.send", "denied.write", null);
    try testing.expectEqual(@as(usize, Emitter.per_root_keys - 1), heldBy(&em, big));
    try testing.expectEqual(@as(usize, 1), heldBy(&em, fresh));
    try testing.expectEqual(@as(u64, 0), em.dropped);
    // The caller's own tree is the largest holder: the denial is dropped.
    const before = deniedCount(d);
    em.buckets.clearRetainingCapacity();
    denyWith(d, big, "pane.another", "denied.write", null);
    try testing.expectEqual(before, deniedCount(d));
    try testing.expectEqual(@as(u64, 1), em.dropped);
}

test "the table forgets expired windows and revoked principals when it is full" {
    const d = try daemon();
    defer d.destroy();
    var em: Emitter = undefined;
    install(d, &em);
    defer em.deinit();
    em.now_ms = 0;
    const ids = try manyPrincipals(d, Emitter.max_tracked);
    defer ta.free(ids);
    for (ids) |id| denyWith(d, id, "pane.send", "denied.write", null);
    try testing.expectEqual(@as(usize, Emitter.max_tracked), em.last_denied.count());
    // Expired: after the window every entry can go.
    const a = try d.principal(&.{.{ .right = .read, .scope = "*" }}, null);
    em.now_ms = Emitter.window_ms;
    denyWith(d, a, "pane.send", "denied.write", null);
    try testing.expectEqual(@as(usize, 1), em.last_denied.count());
    try testing.expectEqual(@as(u64, 0), em.dropped);
    // Revoked: entries of revoked principals go at once, inside their window.
    em.now_ms = Emitter.window_ms;
    for (ids[0 .. Emitter.max_tracked - 1]) |id| denyWith(d, id, "pane.send", "denied.write", null);
    try testing.expectEqual(@as(usize, Emitter.max_tracked), em.last_denied.count());
    for (ids[0..8]) |id| try d.registry.revoke(.{ .principal = g.owner }, id, g.nowSeconds());
    try testing.expectEqual(@as(usize, Emitter.max_tracked - 8), em.last_denied.count());
    try expectCounts(&em);
    const b = try d.principal(&.{.{ .right = .read, .scope = "*" }}, null);
    denyWith(d, b, "pane.send", "denied.write", null);
    try testing.expectEqual(@as(usize, Emitter.max_tracked - 8 + 1), em.last_denied.count());
    try testing.expectEqual(@as(u64, 0), em.dropped);
}

test "a principal's events per second are bounded whatever the verbs, and the next one counts what was held back" {
    const d = try daemon();
    defer d.destroy();
    var em: Emitter = undefined;
    install(d, &em);
    defer em.deinit();
    const who = try d.principal(&.{.{ .right = .read, .scope = "*" }}, null);
    const other = try d.principal(&.{.{ .right = .read, .scope = "*" }}, null);
    em.now_ms = 10_000;
    var verb: [16]u8 = undefined;
    for (0..20) |i| denyWith(d, who, std.fmt.bufPrint(&verb, "pane.v{d}", .{i}) catch unreachable, "denied.write", null);
    try testing.expectEqual(@as(usize, Emitter.burst), deniedCount(d));
    try testing.expect(!entriesContain(d, "suppressed"));
    // Another principal has its own bucket.
    denyWith(d, other, "pane.send", "denied.write", null);
    try testing.expectEqual(@as(usize, Emitter.burst + 1), deniedCount(d));
    // Half a second earns one token; the event says how many were held back.
    em.now_ms = 10_500;
    denyWith(d, who, "pane.later", "denied.write", null);
    try testing.expectEqual(@as(usize, Emitter.burst + 2), deniedCount(d));
    try testing.expect(entriesContain(d, "\"suppressed\":16"));
    // The count restarts, and a still-empty bucket counts again.
    denyWith(d, who, "pane.later2", "denied.write", null);
    denyWith(d, who, "pane.later3", "denied.write", null);
    try testing.expectEqual(@as(usize, Emitter.burst + 2), deniedCount(d));
    em.now_ms = 11_000;
    denyWith(d, who, "pane.later4", "denied.write", null);
    try testing.expect(entriesContain(d, "\"suppressed\":2"));
}

test "admit takes nothing until the event is out" {
    const d = try daemon();
    defer d.destroy();
    var em: Emitter = undefined;
    install(d, &em);
    defer em.deinit();
    em.now_ms = 0;
    const who = try d.principal(&.{.{ .right = .read, .scope = "*" }}, null);
    // A failed append never reaches `record`: the same denial is admitted again.
    try testing.expect((try em.admit(who, "pane.send", .write)) != null);
    const second = (try em.admit(who, "pane.send", .write)).?;
    try testing.expectEqual(@as(usize, 0), em.last_denied.count());
    try testing.expectEqual(@as(usize, 0), em.buckets.count());
    em.record(second);
    try testing.expect((try em.admit(who, "pane.send", .write)) == null);
}

test "safeResource keeps a clean short resource and falls back to its kind or nothing" {
    const long = "pane:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const cases = [_]struct { in: []const u8, want: ?[]const u8 }{
        .{ .in = "pane:p1", .want = "pane:p1" },
        .{ .in = "pane:a b", .want = "pane" },
        .{ .in = "pane:", .want = "pane" },
        .{ .in = long, .want = "pane" },
        .{ .in = ":x", .want = null },
        .{ .in = "nocolon", .want = null },
    };
    for (cases) |c| {
        const got = Emitter.safeResource(c.in);
        if (c.want) |w| try testing.expectEqualStrings(w, got.?) else try testing.expect(got == null);
    }
}

test "denials that are not a missing right emit nothing" {
    const d = try daemon();
    defer d.destroy();
    var em: Emitter = undefined;
    install(d, &em);
    defer em.deinit();
    const who = try d.principal(&.{.{ .right = .read, .scope = "*" }}, null);
    const before = d.events.high;
    for ([_][]const u8{ "denied.token", "denied.event_scope", "denied.revoked", "denied.namespace", "denied.bind", "denied.delegation", "unavailable.busy" }) |code| denyWith(d, who, "events", code, null);
    try testing.expectEqual(before, d.events.high);
}

test "sweep announces expired and exited revocations; restored process principals are created" {
    const d = try daemon();
    defer d.destroy();
    var em: Emitter = undefined;
    install(d, &em);
    defer em.deinit();
    const now = g.nowSeconds();
    const gs = [_]g.Grant{.{ .right = .read, .scope = "*" }};
    const short = try d.registry.issueChild(.{ .principal = g.owner }, .{ .kind = .token, .ttl = 5, .grants = &gs }, now);
    defer ta.free(short.token);
    const dead = try d.registry.issueChild(.{ .principal = g.owner }, .{ .kind = .agent, .root = .{ .pid = std.c.getpid(), .start = 1 }, .grants = &gs }, now);
    defer ta.free(dead.token);
    const restored = try d.registry.restoreProcess(g.owner, .{ .pid = std.c.getpid(), .start = 1 }, &gs, "", null, null);
    try testing.expect(entriesContain(d, "\"kind\":\"process\""));
    d.registry.sweep(now + 10);
    var owner = d.connection(g.owner);
    defer owner.deinit();
    const out = try subscribe(d, &owner);
    defer ta.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"reason\":\"expired\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"reason\":\"exited\"") != null);
    try testing.expectEqual(@as(usize, 3), count(out, "\"type\":\"principal.revoked\""));
    _ = restored;
}

test "a silenced revocation is skipped once; the next revocation is announced" {
    const d = try daemon();
    defer d.destroy();
    var em: Emitter = undefined;
    install(d, &em);
    defer em.deinit();
    const gs = [_]g.Grant{.{ .right = .read, .scope = "*" }};
    const first = try d.registry.issueChild(.{ .principal = g.owner }, .{ .kind = .pane, .pane = "p3", .grants = &gs }, g.nowSeconds());
    defer ta.free(first.token);
    const second = try d.registry.issueChild(.{ .principal = g.owner }, .{ .kind = .pane, .pane = "p4", .grants = &gs }, g.nowSeconds());
    defer ta.free(second.token);
    const before = d.events.high;
    em.silence(first.principal);
    try d.registry.revoke(.{ .principal = g.owner }, first.principal, g.nowSeconds());
    try testing.expectEqual(before, d.events.high);
    // A second revoke of the same principal changes nothing and announces nothing.
    try d.registry.revoke(.{ .principal = g.owner }, first.principal, g.nowSeconds());
    try testing.expectEqual(before, d.events.high);
    try d.registry.revoke(.{ .principal = g.owner }, second.principal, g.nowSeconds());
    try testing.expectEqual(before + 1, d.events.high);
}

/// The per-tree and per-principal key counts equal a recount of `last_denied`.
fn expectCounts(em: *const Emitter) !void {
    var roots: usize = 0;
    var owned: usize = 0;
    var it = em.roots.iterator();
    while (it.next()) |e| {
        try testing.expect(e.value_ptr.keys > 0 or e.value_ptr.held_n > 0);
        var hn: u32 = 0;
        var hit = em.held.valueIterator();
        while (hit.next()) |h| {
            if (h.root == e.key_ptr.*) hn += 1;
        }
        try testing.expectEqual(hn, e.value_ptr.held_n);
        try testing.expectEqual(@as(usize, e.value_ptr.keys), heldBy(em, e.key_ptr.*));
        roots += e.value_ptr.keys;
        // The list runs oldest to newest and visits every key once.
        var n: u32 = 0;
        var prev: ?Emitter.DeniedKey = null;
        var cur = e.value_ptr.head;
        while (cur) |k| : (n += 1) {
            const w = em.last_denied.get(k).?;
            try testing.expectEqual(e.key_ptr.*, w.root);
            try testing.expect(std.meta.eql(prev, w.prev));
            if (prev) |pk| try testing.expect(em.last_denied.get(pk).?.last <= w.last);
            prev = k;
            cur = w.next;
        }
        try testing.expectEqual(e.value_ptr.keys, n);
        try testing.expect(std.meta.eql(prev, e.value_ptr.tail));
    }
    var ot = em.owned.iterator();
    while (ot.next()) |e| {
        var n: u32 = 0;
        var kt = em.last_denied.keyIterator();
        while (kt.next()) |k| {
            if (k.principal == e.key_ptr.*) n += 1;
        }
        try testing.expectEqual(n, e.value_ptr.*);
        owned += n;
    }
    try testing.expectEqual(em.last_denied.count(), roots);
    try testing.expectEqual(em.last_denied.count(), owned);
}

test "per-tree and per-principal key counts follow every way a key is added or removed" {
    const d = try daemon();
    defer d.destroy();
    var em: Emitter = undefined;
    install(d, &em);
    defer em.deinit();
    em.now_ms = 0;
    const top = try d.principal(&spawner_grants, null);
    const k1 = try child(d, top);
    const k2 = try child(d, top);
    holdKeys(d, &em, k1, 4);
    holdKeys(d, &em, k2, 4);
    try expectCounts(&em);
    try testing.expectEqual(@as(u32, 8), em.roots.get(top).?.keys);
    // Expiry: a new key after the window retires the tree's old ones.
    em.now_ms = 2 * Emitter.window_ms;
    em.buckets.clearRetainingCapacity();
    denyWith(d, k1, "pane.fresh", "denied.write", null);
    try expectCounts(&em);
    try testing.expectEqual(@as(u32, 1), em.roots.get(top).?.keys);
    // Revocation drops the principal's keys.
    try d.registry.revoke(.{ .principal = g.owner }, k1, g.nowSeconds());
    try expectCounts(&em);
    try testing.expectEqual(@as(usize, 0), em.last_denied.count());
    try testing.expectEqual(@as(usize, 0), em.roots.count());
    try testing.expectEqual(@as(usize, 0), em.owned.count());
    // Full-table eviction.
    em.now_ms = 3 * Emitter.window_ms;
    const ids = try manyPrincipals(d, Emitter.max_tracked + 20);
    defer ta.free(ids);
    for (ids) |id| denyWith(d, id, "pane.send", "denied.write", null);
    try expectCounts(&em);
    try testing.expect(em.last_denied.count() <= Emitter.max_tracked);
}

test "a tree's principal.denied events per second are bounded however many children it spawns" {
    const d = try daemon();
    defer d.destroy();
    var em: Emitter = undefined;
    install(d, &em);
    defer em.deinit();
    em.now_ms = 10_000;
    const top = try d.principal(&spawner_grants, null);
    const other = try d.principal(&.{.{ .right = .read, .scope = "*" }}, null);
    var verb: [16]u8 = undefined;
    var last: g.Id = top;
    for (0..50) |_| {
        last = try child(d, top);
        for (0..4) |i| denyWith(d, last, verbName(&verb, i), "denied.write", null);
    }
    try testing.expectEqual(@as(usize, Emitter.burst), deniedCount(d));
    // Another tree has its own bucket.
    denyWith(d, other, "pane.send", "denied.write", null);
    try testing.expectEqual(@as(usize, Emitter.burst + 1), deniedCount(d));
    // One second later the tree has earned rate_per_s more, whoever asks, and
    // the event carries what was held back.
    em.now_ms = 11_000;
    for (0..10) |i| denyWith(d, last, verbName(&verb, 100 + i), "denied.write", null);
    try testing.expectEqual(@as(usize, Emitter.burst + 1 + Emitter.rate_per_s), deniedCount(d));
    // It reports its own four held-back denials, not the tree's.
    try testing.expect(entriesContain(d, "\"suppressed\":4"));
    try testing.expect(!entriesContain(d, "\"suppressed\":5"));
    try expectCounts(&em);
}

test "minting children cannot grow a tree past its key cap" {
    const d = try daemon();
    defer d.destroy();
    var em: Emitter = undefined;
    install(d, &em);
    defer em.deinit();
    em.now_ms = 0;
    const top = try d.principal(&spawner_grants, null);
    for (0..3 * Emitter.max_root_keys) |_| holdKeys(d, &em, try child(d, top), 1);
    // The cap, and the one fold window that stands for the rest.
    try testing.expect(heldBy(&em, top) <= Emitter.max_root_keys + 1);
    try testing.expect(heldBy(&em, top) > Emitter.per_root_keys);
    try expectCounts(&em);
    // Another tree is not starved by it.
    const other = try d.principal(&.{.{ .right = .read, .scope = "*" }}, null);
    const before = deniedCount(d);
    denyWith(d, other, "pane.send", "denied.write", null);
    try testing.expectEqual(before + 1, deniedCount(d));
}

/// Order-independent hash of every table's content.
fn fingerprint(em: *const Emitter) u64 {
    var sum: u64 = em.dropped;
    inline for (.{ &em.last_denied, &em.buckets, &em.roots, &em.owned, &em.held }) |m| {
        var it = m.iterator();
        while (it.next()) |e| {
            var h = std.hash.Wyhash.init(1);
            std.hash.autoHash(&h, e.key_ptr.*);
            std.hash.autoHash(&h, e.value_ptr.*);
            sum +%= h.final();
        }
        sum +%= @as(u64, m.count()) *% 0x9e3779b97f4a7c15;
    }
    return sum;
}

/// A scenario for the allocation sweeps: the tables a caller arrives to.
const Scene = enum {
    /// A few trees; the caller is a new principal with a new tree.
    sparse,
    /// The key table is full of other trees' windows.
    full,
    /// The caller's tree is at its budget and its fold window is live and its bucket gone.
    fold,
    /// The caller's tree holds expired keys and has no bucket.
    expired,
    /// The caller's tree is at `max_root_keys` and its bucket is live.
    cap,
};

fn setScene(d: *Daemon, em: *Emitter, scene: Scene) !g.Id {
    const rd = [_]g.Grant{.{ .right = .read, .scope = "*" }};
    em.now_ms = 0;
    switch (scene) {
        .sparse => {
            for (0..3) |_| {
                const p = try d.principal(&rd, null);
                if (try em.admit(p, "pane.send", .write)) |a| em.record(a);
            }
            return try d.principal(&rd, null);
        },
        .full => {
            const ids = try manyPrincipals(d, Emitter.max_tracked);
            defer ta.free(ids);
            for (ids) |p| if (try em.admit(p, "pane.send", .write)) |a| em.record(a);
            try testing.expectEqual(@as(usize, Emitter.max_tracked), em.last_denied.count());
            return try d.principal(&rd, null);
        },
        .fold, .expired => {
            const top = try d.principal(&spawner_grants, null);
            const k = try child(d, top);
            var verb: [16]u8 = undefined;
            const n: usize = if (scene == .fold) Emitter.per_root_keys + 1 else 8;
            for (0..n) |i| {
                em.buckets.clearRetainingCapacity();
                if (try em.admit(k, verbName(&verb, i), .write)) |a| em.record(a);
            }
            em.buckets.clearRetainingCapacity();
            if (scene == .expired) em.now_ms = 2 * Emitter.window_ms;
            return k;
        },
        .cap => {
            const top = try d.principal(&spawner_grants, null);
            for (0..Emitter.max_root_keys) |_| {
                em.buckets.clearRetainingCapacity();
                if (try em.admit(try child(d, top), "pane.send", .write)) |a| em.record(a);
            }
            try testing.expectEqual(@as(u32, Emitter.max_root_keys), em.roots.get(top).?.keys);
            try testing.expect(em.buckets.count() == 1);
            return try child(d, top);
        },
    }
}

test "an allocation failure in admit leaves every table unchanged and leaks nothing" {
    for ([_]Scene{ .sparse, .full, .fold, .expired, .cap }) |scene| {
        var fail_at: usize = 0;
        while (true) : (fail_at += 1) {
            try testing.expect(fail_at < 64);
            const d = try daemon();
            defer d.destroy();
            var fa = std.testing.FailingAllocator.init(ta, .{});
            var log = try proto.events.Log.init(fa.allocator(), "venomx", .{}, null);
            defer log.deinit();
            var em: Emitter = .{ .events = &log, .registry = &d.registry };
            defer em.deinit();
            const who = try setScene(d, &em, scene);
            const before = fingerprint(&em);
            fa.alloc_index = 0;
            fa.fail_index = fail_at;
            fa.has_induced_failure = false;
            const result = em.admit(who, "pane.kill", .write);
            fa.fail_index = std.math.maxInt(usize);
            if (fa.has_induced_failure) {
                try testing.expectError(error.OutOfMemory, result);
                try testing.expectEqual(before, fingerprint(&em));
                try expectCounts(&em);
                continue;
            }
            // Enough allocations were allowed.
            const maybe = try result;
            if (scene == .fold) {
                // Folded into the busy window: held back, and counted.
                try testing.expect(maybe == null);
                try testing.expectEqual(@as(u32, 1), em.held.get(who).?.suppressed);
            } else {
                em.record(maybe orelse return error.TestUnexpectedResult);
                try testing.expect((try em.admit(who, "pane.kill", .write)) == null);
            }
            try expectCounts(&em);
            try testing.expect(em.last_denied.count() <= Emitter.max_tracked);
            break;
        }
    }
}

test "an allocation failure in emit loses the event, keeps the tables consistent and bounded, and leaks nothing" {
    for ([_]Scene{ .sparse, .full, .fold, .expired, .cap }) |scene| {
        var fail_at: usize = 0;
        while (true) : (fail_at += 1) {
            try testing.expect(fail_at < 64);
            const d = try daemon();
            defer d.destroy();
            var fa = std.testing.FailingAllocator.init(ta, .{});
            var log = try proto.events.Log.init(fa.allocator(), "venomx", .{}, null);
            defer log.deinit();
            log.catalog = &@import("manifest.zig").catalog;
            var em: Emitter = .{ .events = &log, .registry = &d.registry };
            defer em.deinit();
            const who = try setScene(d, &em, scene);
            d.registry.observer = em.observer();
            const before = fingerprint(&em);
            const published = log.entries.items.len - log.head;
            fa.alloc_index = 0;
            fa.fail_index = fail_at;
            fa.has_induced_failure = false;
            denyWith(d, who, "pane.kill", "denied.write", null);
            fa.fail_index = std.math.maxInt(usize);
            d.registry.observer = null;
            try expectCounts(&em);
            try testing.expect(em.last_denied.count() <= Emitter.max_tracked);
            if (!fa.has_induced_failure) break;
            // The event was lost: nothing was taken. Only the sparse scene has
            // nothing that `admit` may already have retired or evicted.
            try testing.expectEqual(published, log.entries.items.len - log.head);
            if (scene == .sparse) try testing.expectEqual(before, fingerprint(&em));
        }
    }
}

test "a tree that mints children cannot fill the held-back table and starve another tree's counts" {
    const d = try daemon();
    defer d.destroy();
    var em: Emitter = undefined;
    install(d, &em);
    defer em.deinit();
    em.now_ms = 0;
    const top = try d.principal(&spawner_grants, null);
    const other = try d.principal(&.{.{ .right = .read, .scope = "*" }}, null);
    var verb: [16]u8 = undefined;
    // Two of the other tree's six denials are held back.
    for (0..6) |i| denyWith(d, other, verbName(&verb, i), "denied.write", null);
    try testing.expectEqual(@as(u32, 2), em.held.get(other).?.suppressed);
    // The minting tree: more children than the table holds, each held back.
    for (0..Emitter.max_tracked + 100) |_| denyWith(d, try child(d, top), "pane.send", "denied.write", null);
    try testing.expect(em.roots.get(top).?.held_n <= Emitter.max_root_keys + 1);
    try testing.expect(em.held.count() <= Emitter.max_root_keys + 2);
    try testing.expectEqual(@as(u64, 0), em.dropped);
    // The overflow is the root's to report; the other tree's count is intact.
    try testing.expect(em.held.get(top).?.suppressed > Emitter.max_tracked / 2);
    try expectCounts(&em);
    em.now_ms = Emitter.window_ms;
    denyWith(d, other, "pane.later", "denied.write", null);
    const last = d.events.entries.items[d.events.entries.items.len - 1].bytes;
    try testing.expect(std.mem.indexOf(u8, last, "\"suppressed\":2") != null);
}
