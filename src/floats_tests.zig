//! Float and popup conformance cases, plus the daemon and client rules
//! for floats, popups with tickets, presets and placement intent. A
//! real `Product` and dispatcher run in process; presentation clients are
//! `attach` Apps fed the daemon's own event log and answered through the
//! dispatcher under their own connection.
const std = @import("std");
const proto = @import("proto");
const cfg = @import("cfg");
const cli = @import("cli");
const g = proto.grants;
const harness = @import("chrome_tests.zig");
const Daemon = harness.Daemon;
const Client = harness.Client;
const floats = @import("floats.zig");
const Product = @import("product.zig").Product;
const a = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const Value = std.json.Value;

/// The error code of a call, or "ok".
fn codeOf(d: *Daemon, conn: *proto.Connection, verb: []const u8, params: []const u8, buf: []u8) ![]const u8 {
    var r = try d.call(conn, verb, params);
    defer r.deinit();
    const e = r.value.object.get("error") orelse return "ok";
    const c = e.object.get("code").?.string;
    @memcpy(buf[0..c.len], c);
    return buf[0..c.len];
}
fn expectCode(d: *Daemon, conn: *proto.Connection, verb: []const u8, params: []const u8, want: []const u8) !void {
    var buf: [64]u8 = undefined;
    const got = try codeOf(d, conn, verb, params, &buf);
    if (!std.mem.eql(u8, got, want)) {
        std.debug.print("{s} {s}: want {s}, got {s}: {s}\n", .{ verb, params, want, got, conn.output.items });
        return error.TestUnexpectedResult;
    }
}
/// Answer every queued client request through the dispatcher under the
/// client's own connection, as the attach transport does.
fn serve(c: *Client, d: *Daemon, conn: *proto.Connection) !void {
    while (c.app.requests.items.len > 0) {
        const r = c.app.requests.orderedRemove(0);
        defer a.free(r.params);
        if (std.mem.eql(u8, r.verb, "config.get") or std.mem.eql(u8, r.verb, "keys.list")) continue;
        var res = try d.call(conn, r.verb, r.params);
        defer res.deinit();
        const reply = if (res.value.object.get("ok")) |ok|
            try std.json.Stringify.valueAlloc(a, .{ .id = r.id, .ok = ok }, .{})
        else
            try std.json.Stringify.valueAlloc(a, .{ .id = r.id, .@"error" = res.value.object.get("error").? }, .{});
        defer a.free(reply);
        try c.app.control(reply);
    }
}
fn dropRequests(c: *Client) void {
    for (c.app.requests.items) |r| a.free(r.params);
    c.app.requests.clearRetainingCapacity();
}
fn okValue(d: *Daemon, conn: *proto.Connection, verb: []const u8, params: []const u8) !std.json.Parsed(Value) {
    const r = try d.call(conn, verb, params);
    if (r.value.object.get("ok") == null) {
        std.debug.print("{s} failed: {s}\n", .{ verb, conn.output.items });
        r.deinit();
        return error.CallFailed;
    }
    return r;
}
/// A ticket minted by the client's own `{popup_ticket}` exec binding.
fn mint(c: *Client, d: *Daemon, conn: *proto.Connection) ![]u8 {
    const argv = [_][]const u8{ "venom", "settings", "--ticket", "{popup_ticket}" };
    try c.app.runTarget(.{ .exec = &argv });
    try expectEqual(@as(usize, 0), c.app.execs.items.len);
    try serve(c, d, conn);
    try expectEqual(@as(usize, 1), c.app.execs.items.len);
    const x = c.app.execs.orderedRemove(0);
    defer x.deinit(a);
    try expectEqualStrings("--ticket", x.argv[2]);
    try expectEqual(@as(usize, 32), x.argv[3].len);
    return a.dupe(u8, x.argv[3]);
}
fn popupParams(ticket: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{{\"ticket\":\"{s}\",\"argv\":[\"true\"],\"preset\":\"venom.settings\"}}", .{ticket});
}
fn screenHas(c: *Client, text: []const u8) !bool {
    const all = try c.screen();
    defer a.free(all);
    return std.mem.indexOf(u8, all, text) != null;
}

test "pane.popup without a ticket, with an expired one or another client's fails; a valid ticket opens it on that client only" {
    const d = try Daemon.create();
    defer d.destroy();
    try harness.topology(d);
    var one = try Client.init(100, 31);
    defer one.deinit();
    var two = try Client.init(100, 31);
    defer two.deinit();
    var one_conn = d.connection(g.owner);
    defer one_conn.deinit();
    var two_conn = d.connection(g.owner);
    defer two_conn.deinit();
    try one.sync(d);
    try two.sync(d);
    // venom acts with spawn on everything, but is no presentation client.
    var venom = d.connection(try d.principal(&.{ .{ .right = .spawn, .scope = "*" }, .{ .right = .write, .scope = "*" }, .{ .right = .read, .scope = "*" } }, "venom"));
    defer venom.deinit();
    // No ticket at all; a made-up one.
    try expectCode(d, &venom, "pane.popup", "{\"argv\":[\"true\"]}", "denied.popup_ticket");
    try expectCode(d, &venom, "pane.popup", "{\"ticket\":\"0123456789abcdef0123456789abcdef\",\"argv\":[\"true\"]}", "denied.popup_ticket");
    // An expired ticket (10 s have passed).
    const stale = try mint(&one, d, &one_conn);
    defer a.free(stale);
    d.product.floats.tickets.items[d.product.floats.tickets.items.len - 1].expires = d.product.leaders.now() - 1;
    const stale_params = try popupParams(stale);
    defer a.free(stale_params);
    try expectCode(d, &venom, "pane.popup", stale_params, "denied.popup_ticket");
    // Another client cannot spend client one's ticket for its own screen.
    const ticket = try mint(&one, d, &one_conn);
    defer a.free(ticket);
    const own = try mint(&two, d, &two_conn);
    defer a.free(own);
    const params = try popupParams(ticket);
    defer a.free(params);
    try expectCode(d, &two_conn, "pane.popup", params, "denied.popup_ticket");
    try expect(!std.mem.eql(u8, one.app.client_id.?, two.app.client_id.?));
    // Without spawn on the ticket's session the call is denied.
    var reader = d.connection(try d.principal(&.{.{ .right = .read, .scope = "*" }}, "reader"));
    defer reader.deinit();
    try expectCode(d, &reader, "pane.popup", params, "denied.spawn");
    // The product passes the valid ticket: the popup opens on client one.
    var opened = try okValue(d, &venom, "pane.popup", params);
    const popup = try a.dupe(u8, opened.value.object.get("ok").?.object.get("pane").?.string);
    opened.deinit();
    defer a.free(popup);
    // Single use.
    try expectCode(d, &venom, "pane.popup", params, "denied.popup_ticket");
    const before_one = try a.dupe(u8, one.app.focus.?);
    defer a.free(before_one);
    try one.sync(d);
    try two.sync(d);
    try expectEqual(@as(usize, 1), one.app.overlays.items.len);
    try expectEqual(floats.Layer.popup, one.app.overlays.items[0].layer);
    try expectEqual(@as(usize, 0), two.app.overlays.items.len);
    // It takes focus on its client only, and is drawn there only.
    try expectEqualStrings(popup, one.app.focus.?);
    try expect(!std.mem.eql(u8, popup, two.app.focus.?));
    try expect(one.app.pane(popup) != null);
    try expect(two.app.pane(popup) == null);
    try expect(try screenHas(&one, "╭"));
    try expect(!try screenHas(&two, "╭"));
    // The popup is not in the split tree.
    var w = try okValue(d, &d.owner, "window.get", "{\"window\":\"w0\"}");
    try expectEqual(@as(usize, 3), w.value.object.get("ok").?.object.get("nodes").?.array.items.len);
    w.deinit();
    // Dismiss (leader x / escape) removes it under the client's identity.
    try one.app.run(.{ .local = .dismiss_popup });
    try expectEqualStrings("pane.kill", one.app.requests.items[one.app.requests.items.len - 1].verb);
    dropRequests(&one);
    // A bare esc dismisses a popup whose process has exited
    // (on_exit=keep), but goes to the process while it still runs.
    const pv = one.app.pane(popup).?;
    _ = try one.app.feedInput("\x1b[27;5u");
    try expectEqual(@as(usize, 0), one.app.requests.items.len);
    try one.app.flushEscape();
    try expectEqual(@as(usize, 0), one.app.requests.items.len);
    pv.stream.exit = .{ .code = 0 };
    _ = try one.app.feedInput("\x1b[27;5u");
    try expectEqual(@as(usize, 0), one.app.requests.items.len);
    try one.app.flushEscape();
    try expectEqualStrings("pane.kill", one.app.requests.items[one.app.requests.items.len - 1].verb);
    dropRequests(&one);
    pv.stream.exit = null;
    // A ticket of a client that has detached fails not_found.client, and
    // that client's popups are hung up and removed.
    const late = try mint(&one, d, &one_conn);
    defer a.free(late);
    const late_params = try popupParams(late);
    defer a.free(late_params);
    const second = try okValue(d, &venom, "pane.popup", late_params);
    const second_id = try a.dupe(u8, second.value.object.get("ok").?.object.get("pane").?.string);
    second.deinit();
    defer a.free(second_id);
    const gone = try mint(&one, d, &one_conn);
    defer a.free(gone);
    Product.connectionClosed(&d.product, &one_conn);
    const gone_params = try popupParams(gone);
    defer a.free(gone_params);
    try expectCode(d, &venom, "pane.popup", gone_params, "not_found.client");
    try expect(d.product.pane(second_id).?.float.?.orphaned);
    // Its process exits; the next turn removes it (on_exit=remove).
    const deadline = @import("server.zig").nowMs() + 5000;
    while (d.product.pane(second_id) != null and @import("server.zig").nowMs() < deadline) {
        try d.product.supervise();
        try d.server.pump(@import("server.zig").nowMs());
        try d.product.tick();
    }
    try expect(d.product.pane(second_id) == null);
}

const FloatsOnly = struct { floats: floats.Config = .{} };
const FloatStore = cfg.Store(FloatsOnly, &.{});

test "a preset change through config set resizes the next float and, after reload, the existing ones" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(base);
    const user = try std.fs.path.join(a, &.{ base, "config.zon" });
    defer a.free(user);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.zon", .data =
        \\.{ .floats = .{ .presets = .{ .@"venom.settings" = .{ .width = "80%", .height = "80%", .anchor = .center, .title = "venom settings" } } } }
    });
    var store = try FloatStore.init(a, .{ .io = std.testing.io, .path = user });
    defer store.deinit();
    const d = try Daemon.create();
    defer d.destroy();
    floats.configure(&d.product, store.current().floats);
    try harness.topology(d);
    try d.ok(&d.owner, "pane.float", "{\"window\":\"w0\",\"argv\":[\"true\"],\"preset\":\"venom.settings\"}");
    var c = try Client.init(100, 31);
    defer c.deinit();
    try c.sync(d);
    // 80% of the 100x30 window area (the status line is the top row).
    try expectEqual(@as(usize, 1), c.app.overlays.items.len);
    try expectEqual(@as(u16, 80), c.app.overlays.items[0].outer.width);
    try expectEqual(@as(u16, 24), c.app.overlays.items[0].outer.height);
    try expect(try screenHas(&c, "venom settings"));
    // It never takes focus by being created.
    try expectEqualStrings("p0", c.app.focus.?);
    // The pane's viewport (and so its PTY size) is the inner rectangle.
    try expectEqual(@as(u16, 78), c.app.pane("p3").?.rect.width);
    // `config set` writes the user file; the active config changes at reload.
    try expect((try store.set("floats.presets.venom.settings.width", "\"90%\"")).changed);
    floats.configure(&d.product, store.current().floats);
    try c.sync(d);
    try expectEqual(@as(u16, 80), c.app.overlays.items[0].outer.width);
    const high = d.events.high;
    _ = try store.reload();
    floats.configure(&d.product, store.current().floats);
    // One pane.placed for the existing float, then every client re-resolves.
    try expectEqual(high + 1, d.events.high);
    const tail = d.events.entries.items[d.events.entries.items.len - 1];
    try expectEqualStrings("pane.placed", tail.type);
    try c.sync(d);
    try expectEqual(@as(u16, 90), c.app.overlays.items[0].outer.width);
    try expectEqual(@as(u16, 24), c.app.overlays.items[0].outer.height);
    // The next float gets the new preset; explicit fields override it.
    var next = try okValue(d, &d.owner, "pane.float", "{\"window\":\"w0\",\"argv\":[\"true\"],\"preset\":\"venom.settings\",\"height\":\"10\",\"anchor\":\"top\"}");
    next.deinit();
    try c.sync(d);
    const o = c.app.overlay("p4").?;
    try expectEqual(@as(u16, 90), o.outer.width);
    try expectEqual(@as(u16, 10), o.outer.height);
    try expectEqual(@as(u16, 1), o.outer.y);
    // A later float is above an earlier one; raise reorders.
    try expect(o.z > c.app.overlay("p3").?.z);
    try d.ok(&d.owner, "pane.raise", "{\"pane\":\"p3\"}");
    try c.sync(d);
    try expect(c.app.overlay("p3").?.z > c.app.overlay("p4").?.z);
    // An unknown preset falls back to floats.default and doctor reports it.
    try d.ok(&d.owner, "pane.float", "{\"window\":\"w0\",\"argv\":[\"true\"],\"preset\":\"venom.nope\"}");
    try c.sync(d);
    try expectEqual(@as(u16, 60), c.app.overlay("p5").?.outer.width);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var report: cli.doctor.Report = .{ .arena = arena.allocator(), .tool = "venomx" };
    try floats.doctor(&report, &d.product);
    try expectEqual(cli.doctor.Status.warn, report.results.items[0].status);
    try expect(std.mem.indexOf(u8, report.results.items[0].message, "p5 (venom.nope)") != null);
    // Bad sizes are invalid_params.geometry; an invalid preset value fails config.
    try expectCode(d, &d.owner, "pane.float", "{\"window\":\"w0\",\"argv\":[\"true\"],\"width\":\"wide\"}", "invalid_params.geometry");
    try expectCode(d, &d.owner, "pane.float", "{\"window\":\"w0\",\"argv\":[\"true\"],\"preset\":\"nonamespace\"}", "invalid_params.geometry");
    try std.testing.expectError(error.InvalidConfig, (floats.Config{ .presets = .{ .entries = &.{.{ .name = "venom.x", .value = .{ .width = "200%" } }} } }).check());
}

test "floats: per-client visibility, toggle-floats, focus cycling, place and raise, removal keeps the layout" {
    const d = try Daemon.create();
    defer d.destroy();
    try harness.topology(d);
    var one = try Client.init(100, 31);
    defer one.deinit();
    var two = try Client.init(100, 31);
    defer two.deinit();
    try one.sync(d);
    try two.sync(d);
    try two.app.run(.{ .local = .window_next });
    const layout_revision = d.product.pane("p0").?.window.revision;
    var made = try okValue(d, &d.owner, "pane.float", "{\"window\":\"w0\",\"argv\":[\"true\"],\"title\":\"logs\",\"tags\":[{\"key\":\"role\",\"value\":\"log\"}]}");
    try expectEqualStrings("w0", made.value.object.get("ok").?.object.get("window").?.string);
    made.deinit();
    try expectEqual(layout_revision, d.product.pane("p0").?.window.revision);
    try one.sync(d);
    try two.sync(d);
    // Shown by the client on w0, not by the one on w1.
    try expect(one.app.visibleNow("p3"));
    try expect(!two.app.visibleNow("p3"));
    try expect(try screenHas(&one, "logs"));
    // toggle-floats hides the layer on this client only.
    try one.app.run(.{ .local = .toggle_floats });
    try expect(!one.app.visibleNow("p3"));
    try one.app.run(.{ .local = .toggle_floats });
    try expect(one.app.visibleNow("p3"));
    // leader F cycles focus among visible floats.
    try one.app.run(.{ .local = .focus_float });
    try expectEqualStrings("p3", one.app.focus.?);
    try expectEqualStrings("p2", two.app.focus.?);
    // Mouse: the float is above the tiled pane under it.
    const o = one.app.overlay("p3").?;
    try expect(o.outer.width > 0);
    // Floats do not split; tiled panes do.
    try expectCode(d, &d.owner, "pane.split", "{\"pane\":\"p3\",\"axis\":\"cols\",\"argv\":[\"true\"]}", "conflict.layer");
    try expectCode(d, &d.owner, "pane.raise", "{\"pane\":\"p0\"}", "conflict.layer");
    // window.get lists the float layer; the snapshot carries it per pane.
    {
        var w = try okValue(d, &d.owner, "window.get", "{\"window\":\"w0\"}");
        defer w.deinit();
        const fl = w.value.object.get("ok").?.object.get("floats").?.array.items;
        try expectEqual(@as(usize, 1), fl.len);
        try expectEqualStrings("p3", fl[0].object.get("pane").?.string);
    }
    var snap = std.heap.ArenaAllocator.init(a);
    defer snap.deinit();
    const entities = try d.product.capture(snap.allocator());
    var found = false;
    for (entities) |e| if (std.mem.eql(u8, e.resource, "pane:p3")) {
        found = true;
        try expect(std.mem.indexOf(u8, e.content, "\"layer\":\"float\"") != null);
        try expect(std.mem.indexOf(u8, e.content, "\"z\":") != null);
    };
    try expect(found);
    // Tile it next to p0, then float p1 out of the tree.
    {
        var r = try okValue(d, &d.owner, "pane.place", "{\"pane\":\"p3\",\"tile\":{\"target\":\"p0\",\"axis\":\"rows\"}}");
        defer r.deinit();
        try expectEqualStrings("tile", r.value.object.get("ok").?.object.get("layer").?.string);
    }
    try one.sync(d);
    try expect(one.app.overlay("p3") == null);
    try expect(one.app.visibleNow("p3"));
    try d.ok(&d.owner, "pane.place", "{\"pane\":\"p1\",\"float\":{\"width\":\"40\",\"height\":\"10\",\"anchor\":\"bottom_right\",\"border\":\"heavy\"}}");
    try one.sync(d);
    const p1 = one.app.overlay("p1").?;
    try expectEqual(@as(u16, 40), p1.outer.width);
    try expectEqual(@as(u16, 60), p1.outer.x);
    try expectEqual(@as(u16, 21), p1.outer.y);
    try expect(try screenHas(&one, "┏"));
    try expectCode(d, &d.owner, "pane.place", "{\"pane\":\"p1\"}", "invalid_params.place");
    try expectCode(d, &d.owner, "pane.place", "{\"pane\":\"p1\",\"tile\":{\"target\":\"p2\",\"axis\":\"rows\"}}", "invalid_params.place");
    // Removing an exited float changes no layout; the window stays while
    // a float remains even with no tiled pane.
    const rev = d.product.pane("p0").?.window.revision;
    d.product.pane("p1").?.pane.status = .{ .code = 0 };
    try d.ok(&d.owner, "pane.remove", "{\"pane\":\"p1\"}");
    try expectEqual(rev, d.product.pane("p0").?.window.revision);
    try one.sync(d);
    try expect(one.app.overlay("p1") == null);
    try expectCode(d, &d.owner, "window.remove", "{\"window\":\"w1\"}", "conflict.not_empty");
    try d.ok(&d.owner, "pane.float", "{\"window\":\"w1\",\"argv\":[\"true\"]}");
    d.product.pane("p2").?.pane.status = .{ .code = 0 };
    try d.ok(&d.owner, "pane.remove", "{\"pane\":\"p2\"}");
    try expect(d.product.pane("p4") != null);
    try expectCode(d, &d.owner, "window.remove", "{\"window\":\"w1\"}", "conflict.not_empty");
}

test "near placement: pane.split and window.create split the largest matching pane" {
    const d = try Daemon.create();
    defer d.destroy();
    try harness.topology(d);
    // p2 (w1) is the given target; near picks thread-7's pane p1 in w0.
    var r = try okValue(d, &d.owner, "pane.split", "{\"pane\":\"p2\",\"axis\":\"rows\",\"argv\":[\"true\"],\"near\":[{\"key\":\"group\",\"value\":\"thread-7\"}]}");
    try expectEqualStrings("w0", r.value.object.get("ok").?.object.get("window").?.string);
    r.deinit();
    // No match: the given target.
    r = try okValue(d, &d.owner, "pane.split", "{\"pane\":\"p2\",\"axis\":\"rows\",\"argv\":[\"true\"],\"near\":[{\"key\":\"group\",\"value\":\"none\"}]}");
    try expectEqualStrings("w1", r.value.object.get("ok").?.object.get("window").?.string);
    r.deinit();
    // window.create with a match splits it instead of opening a window.
    const windows = d.product.windows.items.len;
    r = try okValue(d, &d.owner, "window.create", "{\"session\":\"s0\",\"argv\":[\"true\"],\"near\":[{\"key\":\"role\",\"value\":\"agent\"}]}");
    try expectEqualStrings("w0", r.value.object.get("ok").?.object.get("window").?.string);
    r.deinit();
    try expectEqual(windows, d.product.windows.items.len);
    r = try okValue(d, &d.owner, "window.create", "{\"session\":\"s0\",\"argv\":[\"true\"],\"near\":[{\"key\":\"role\",\"value\":\"nobody\"}]}");
    try expectEqualStrings("w2", r.value.object.get("ok").?.object.get("window").?.string);
    r.deinit();
    // A principal that may not spawn in the matching pane's window is not
    // placed there.
    var limited = d.connection(try d.principal(&.{ .{ .right = .spawn, .scope = "window:w1" }, .{ .right = .read, .scope = "*" } }, "venom"));
    defer limited.deinit();
    r = try okValue(d, &limited, "pane.split", "{\"pane\":\"p2\",\"axis\":\"rows\",\"argv\":[\"true\"],\"near\":[{\"key\":\"group\",\"value\":\"thread-7\"}]}");
    try expectEqualStrings("w1", r.value.object.get("ok").?.object.get("window").?.string);
    r.deinit();
}

test "floats.register: namespaced product presets, config wins, connection-bound" {
    const d = try Daemon.create();
    defer d.destroy();
    try harness.topology(d);
    var venom = d.connection(try d.principal(&.{ .{ .right = .write, .scope = "*" }, .{ .right = .spawn, .scope = "*" }, .{ .right = .read, .scope = "*" } }, "venom"));
    try d.ok(&venom, "floats.register", "{\"name\":\"venom.diff\",\"width\":\"100%\",\"height\":\"70%\",\"anchor\":\"bottom\"}");
    try expectCode(d, &venom, "floats.register", "{\"name\":\"venom-os.launcher\",\"width\":\"50%\"}", "denied.namespace");
    try expectCode(d, &venom, "floats.register", "{\"name\":\"venom.bad\",\"height\":\"0\"}", "invalid_params.geometry");
    try d.ok(&venom, "pane.float", "{\"window\":\"w0\",\"argv\":[\"true\"],\"preset\":\"venom.diff\"}");
    var c = try Client.init(100, 31);
    defer c.deinit();
    try c.sync(d);
    try expectEqual(@as(u16, 100), c.app.overlay("p3").?.outer.width);
    try expectEqual(@as(u16, 21), c.app.overlay("p3").?.outer.height);
    // User config wins field by field over the registered preset.
    floats.configure(&d.product, .{ .presets = .{ .entries = &.{.{ .name = "venom.diff", .value = .{ .height = "50%" } }} } });
    try c.sync(d);
    try expectEqual(@as(u16, 100), c.app.overlay("p3").?.outer.width);
    try expectEqual(@as(u16, 15), c.app.overlay("p3").?.outer.height);
    floats.configure(&d.product, .{});
    // venom's connection closes: its preset goes, the float falls back.
    d.server.closed(&venom);
    venom.deinit();
    try c.sync(d);
    try expectEqual(@as(u16, 60), c.app.overlay("p3").?.outer.width);
    try expect(d.product.pane("p3").?.float.?.unknown);
}

test "a client's own pane.popup binding mints and uses its ticket" {
    const d = try Daemon.create();
    defer d.destroy();
    try harness.topology(d);
    var c = try Client.init(100, 31);
    defer c.deinit();
    var conn = d.connection(g.owner);
    defer conn.deinit();
    try c.sync(d);
    try c.app.runTarget(.{ .verb = .{ .name = "pane.popup", .args = "{\"argv\":[\"true\"],\"title\":\"picker\"}" } });
    try expectEqualStrings("popup.ticket", c.app.requests.items[c.app.requests.items.len - 1].verb);
    try serve(&c, d, &conn);
    try c.sync(d);
    try expectEqual(@as(usize, 1), c.app.overlays.items.len);
    try expectEqualStrings("p3", c.app.focus.?);
    try expect(try screenHas(&c, "picker"));
    // Closing it returns focus to where the human was.
    d.product.pane("p3").?.pane.status = .{ .code = 0 };
    try d.ok(&d.owner, "pane.remove", "{\"pane\":\"p3\"}");
    try c.sync(d);
    try expectEqual(@as(usize, 0), c.app.overlays.items.len);
    try expectEqualStrings("p0", c.app.focus.?);
    // A spliced placeholder never reaches a binding (keys.zig), and without
    // a session the ticket cannot be minted.
    var lone = try @import("attach_app.zig").App.init(a, .{ .pane = "p0" }, .{ .cols = 80, .rows = 24 }, .{});
    defer lone.deinit();
    try lone.runTarget(.{ .exec = &.{ "venom", "{popup_ticket}" } });
    try expectEqual(@as(usize, 0), lone.execs.items.len);
    try expect(std.mem.indexOf(u8, lone.message.items, "{popup_ticket}") != null);
}

test "leader e floats the focused tiled pane and tiles the focused float back" {
    const d = try Daemon.create();
    defer d.destroy();
    try harness.topology(d);
    var c = try Client.init(100, 31);
    defer c.deinit();
    var conn = d.connection(g.owner);
    defer conn.deinit();
    try c.sync(d);
    try expectEqualStrings("p0", c.app.focus.?);
    // Floating while this client hides floats shows them again.
    try c.app.run(.{ .local = .toggle_floats });
    try expect(c.app.floats_hidden);
    _ = try c.app.feedInput("\x02e");
    try expect(!c.app.floats_hidden);
    const r = c.app.requests.items[c.app.requests.items.len - 1];
    try expectEqualStrings("pane.place", r.verb);
    try expectEqualStrings("{\"pane\":\"p0\",\"float\":{}}", r.params);
    try serve(&c, d, &conn);
    try c.sync(d);
    try expectEqual(floats.Layer.float, c.app.overlay("p0").?.layer);
    try expectEqualStrings("p0", c.app.focus.?);
    try expectEqual(@as(usize, 1), d.product.pane("p1").?.window.nodes.len);
    // Back: the only tile p1 is wide, so p0 goes next to it on cols.
    try c.app.run(.{ .verb = .toggle_pane_float });
    try expectEqualStrings("{\"pane\":\"p0\",\"tile\":{\"target\":\"p1\",\"axis\":\"cols\"}}", c.app.requests.items[c.app.requests.items.len - 1].params);
    try serve(&c, d, &conn);
    try c.sync(d);
    try expect(c.app.overlay("p0") == null);
    try expect(c.app.visibleNow("p0"));
    try expectEqualStrings("p0", c.app.focus.?);
    try expectEqual(@as(usize, 3), d.product.pane("p1").?.window.nodes.len);
    // A tall target splits on rows: float p1 out of a 3-wide window.
    try d.ok(&d.owner, "pane.split", "{\"pane\":\"p1\",\"axis\":\"cols\",\"argv\":[\"true\"]}");
    try c.sync(d);
    try c.app.run(.{ .verb = .toggle_pane_float });
    try serve(&c, d, &conn);
    try c.sync(d);
    try c.app.run(.{ .verb = .toggle_pane_float });
    const tall = c.app.requests.items[c.app.requests.items.len - 1].params;
    try expect(std.mem.indexOf(u8, tall, "\"axis\":\"rows\"") != null);
    dropRequests(&c);
    // With no tile left, a float becomes the window's only tile.
    for ([_][]const u8{ "p1", "p3" }) |id| {
        const params = try std.fmt.allocPrint(a, "{{\"pane\":\"{s}\",\"float\":{{}}}}", .{id});
        defer a.free(params);
        try d.ok(&d.owner, "pane.place", params);
    }
    try c.sync(d);
    try expectEqual(@as(usize, 0), d.product.pane("p0").?.window.nodes.len);
    try c.app.run(.{ .verb = .toggle_pane_float });
    try expectEqualStrings("{\"pane\":\"p0\",\"tile\":{}}", c.app.requests.items[c.app.requests.items.len - 1].params);
    try serve(&c, d, &conn);
    try c.sync(d);
    try expectEqual(@as(usize, 1), d.product.pane("p0").?.window.nodes.len);
    try expect(c.app.overlay("p0") == null);
    // A popup is never placed.
    try c.app.runTarget(.{ .verb = .{ .name = "pane.popup", .args = "{\"argv\":[\"true\"]}" } });
    try serve(&c, d, &conn);
    try c.sync(d);
    try expectEqual(floats.Layer.popup, c.app.overlay(c.app.focus.?).?.layer);
    try c.app.run(.{ .verb = .toggle_pane_float });
    try expectEqual(@as(usize, 0), c.app.requests.items.len);
    try expect(std.mem.indexOf(u8, c.app.message.items, "popups cannot be placed") != null);
}

/// w0 gets float p3: 40x10 cells with a single border at (5, 3) of the
/// window area, focused on `c`.
fn floatAt(d: *Daemon, c: *Client) !*@import("attach_app.zig").Overlay {
    try d.ok(&d.owner, "pane.float", "{\"window\":\"w0\",\"argv\":[\"true\"],\"width\":\"40\",\"height\":\"10\",\"anchor\":\"top_left\",\"x\":5,\"y\":3,\"border\":\"single\",\"min_cols\":10,\"min_rows\":4}");
    try c.sync(d);
    try c.app.run(.{ .local = .focus_float });
    try expectEqualStrings("p3", c.app.focus.?);
    return c.app.overlay("p3").?;
}
/// Left-button SGR mouse input at window cells (x, y): `M` press or drag
/// (`code` 32), `m` release.
fn sgr(c: *Client, code: u8, x: u16, y: u16, final: u8) !void {
    var buf: [32]u8 = undefined;
    _ = try c.app.feedInput(try std.fmt.bufPrint(&buf, "\x1b[<{d};{d};{d}{c}", .{ code, x + 1, y + 1, final }));
}
fn drag(c: *Client, from_x: u16, from_y: u16, to_x: u16, to_y: u16) !void {
    try sgr(c, 0, from_x, from_y, 'M');
    try sgr(c, 32, to_x, to_y, 'M');
    try sgr(c, 0, to_x, to_y, 'm');
}

test "resize keys resize a focused float on every client; a refused place puts it back" {
    const d = try Daemon.create();
    defer d.destroy();
    try harness.topology(d);
    var c = try Client.init(100, 31);
    defer c.deinit();
    var other = try Client.init(100, 31);
    defer other.deinit();
    var conn = d.connection(g.owner);
    defer conn.deinit();
    try c.sync(d);
    try other.sync(d);
    var o = try floatAt(d, &c);
    const start = o.outer;
    try expectEqual(@as(u16, 40), start.width);
    try expectEqual(@as(u16, 10), start.height);
    // right grows, top-left fixed; drawn at once, sent as cells.
    try c.app.run(.{ .verb = .resize_right });
    try expectEqual(@as(u16, 41), c.app.overlay("p3").?.outer.width);
    const r = c.app.requests.items[c.app.requests.items.len - 1];
    try expectEqualStrings("pane.place", r.verb);
    try expect(std.mem.indexOf(u8, r.params, "\"width\":\"41\",\"height\":\"10\",\"anchor\":\"top_left\"") != null);
    try expect(std.mem.indexOf(u8, r.params, "\"border\":\"single\",\"min_cols\":10,\"min_rows\":4") != null);
    // Two quick presses before the first lands both count.
    try c.app.run(.{ .verb = .resize_down });
    try serve(&c, d, &conn);
    try c.sync(d);
    try other.sync(d);
    o = c.app.overlay("p3").?;
    try expect(o.pinned == null);
    try expectEqual(@as(u16, 41), o.outer.width);
    try expectEqual(@as(u16, 11), o.outer.height);
    try expectEqual(start.x, o.outer.x);
    try expectEqual(start.y, o.outer.y);
    try expectEqual(@as(u16, 41), other.app.overlay("p3").?.outer.width);
    // left and up shrink; never below min_cols / min_rows.
    for (0..40) |_| {
        try c.app.run(.{ .verb = .resize_left });
        try c.app.run(.{ .verb = .resize_up });
    }
    try serve(&c, d, &conn);
    try c.sync(d);
    o = c.app.overlay("p3").?;
    try expectEqual(@as(u16, 10), o.outer.width);
    try expectEqual(@as(u16, 4), o.outer.height);
    // Growing at the window's right edge pushes the float back in.
    try d.ok(&d.owner, "pane.place", "{\"pane\":\"p3\",\"float\":{\"width\":\"20\",\"height\":\"5\",\"anchor\":\"top_right\",\"border\":\"single\"}}");
    try c.sync(d);
    try c.app.run(.{ .verb = .resize_right });
    o = c.app.overlay("p3").?;
    try expectEqual(@as(u16, 21), o.outer.width);
    try expectEqual(@as(u16, 100), o.outer.x + o.outer.width);
    dropRequests(&c);
    // A refused place drops the pin: the float is back where the daemon has it.
    try c.app.run(.{ .verb = .resize_down });
    const req = c.app.requests.orderedRemove(c.app.requests.items.len - 1);
    a.free(req.params);
    try expect(c.app.overlay("p3").?.pinned != null);
    var buf: [64]u8 = undefined;
    try c.app.control(try std.fmt.bufPrint(&buf, "{{\"id\":{d},\"error\":{{\"code\":\"denied.grant\"}}}}", .{req.id}));
    o = c.app.overlay("p3").?;
    try expect(o.pinned == null);
    try expectEqual(@as(u16, 5), o.outer.height);
    // A tiled pane still moves its divider.
    try c.app.run(.{ .local = .focus_next });
    try expect(c.app.overlay(c.app.focus.?) == null);
    try c.app.run(.{ .verb = .resize_right });
    try expectEqualStrings("pane.resize", c.app.requests.items[c.app.requests.items.len - 1].verb);
    dropRequests(&c);
}

test "mouse moves a float by its title line or after the leader, and resizes it by its other borders" {
    const d = try Daemon.create();
    defer d.destroy();
    try harness.topology(d);
    var c = try Client.init(100, 31);
    defer c.deinit();
    var conn = d.connection(g.owner);
    defer conn.deinit();
    try c.sync(d);
    var o = try floatAt(d, &c);
    var s = o.outer;
    // A plain press inside goes to the pane, not a drag.
    try sgr(&c, 0, s.x + 5, s.y + 5, 'M');
    try expect(c.app.float_drag == null);
    try sgr(&c, 0, s.x + 5, s.y + 5, 'm');
    try expectEqual(@as(usize, 0), c.app.requests.items.len);
    // After the leader, a press inside moves it; the leader is spent.
    _ = try c.app.feedInput("\x02");
    try expect(c.app.leaderPending());
    try sgr(&c, 0, s.x + 5, s.y + 5, 'M');
    try expect(!c.app.leaderPending());
    try sgr(&c, 32, s.x + 8, s.y + 7, 'M');
    // Previewed locally while held.
    try expectEqual(s.x + 3, c.app.overlay("p3").?.outer.x);
    try expectEqual(@as(usize, 0), c.app.requests.items.len);
    try sgr(&c, 0, s.x + 8, s.y + 7, 'm');
    try expectEqual(@as(usize, 1), c.app.requests.items.len);
    try serve(&c, d, &conn);
    try c.sync(d);
    o = c.app.overlay("p3").?;
    try expect(o.pinned == null);
    try expectEqual(s.x + 3, o.outer.x);
    try expectEqual(s.y + 2, o.outer.y);
    try expectEqual(s.width, o.outer.width);
    s = o.outer;
    // The title line drags without the leader, clamped to the window area.
    try drag(&c, s.x + 4, s.y, 0, 0);
    try serve(&c, d, &conn);
    try c.sync(d);
    o = c.app.overlay("p3").?;
    try expectEqual(@as(u16, 0), o.outer.x);
    // The window area starts below a top status line.
    try expectEqual(@as(u16, if (c.app.statusRow() == 0) 1 else 0), o.outer.y);
    s = o.outer;
    // The right border widens it; the bottom-left corner moves the left
    // edge and the bottom.
    try drag(&c, s.x + s.width - 1, s.y + 3, s.x + s.width + 9, s.y + 3);
    try serve(&c, d, &conn);
    try c.sync(d);
    o = c.app.overlay("p3").?;
    try expectEqual(s.width + 10, o.outer.width);
    try expectEqual(s.x, o.outer.x);
    s = o.outer;
    try drag(&c, s.x, s.y + s.height - 1, s.x + 6, s.y + s.height + 1);
    try serve(&c, d, &conn);
    try c.sync(d);
    o = c.app.overlay("p3").?;
    try expectEqual(s.x + 6, o.outer.x);
    try expectEqual(s.width - 6, o.outer.width);
    try expectEqual(s.height + 2, o.outer.height);
    s = o.outer;
    // Shrinking stops at min_cols.
    try drag(&c, s.x + s.width - 1, s.y + 2, 0, s.y + 2);
    try serve(&c, d, &conn);
    try c.sync(d);
    try expectEqual(@as(u16, 10), c.app.overlay("p3").?.outer.width);
    // A click on a border without moving sends nothing and keeps focus there.
    try c.app.run(.{ .local = .focus_next });
    s = c.app.overlay("p3").?.outer;
    try sgr(&c, 0, s.x + 2, s.y, 'M');
    try sgr(&c, 0, s.x + 2, s.y, 'm');
    try expectEqual(@as(usize, 0), c.app.requests.items.len);
    try expectEqualStrings("p3", c.app.focus.?);
    try expect(c.app.overlay("p3").?.pinned == null);
}

test "the pane blocks list the window's floats; hidden ones stay, dimmed with ⊘" {
    const d = try Daemon.create();
    defer d.destroy();
    try harness.topology(d);
    var c = try Client.init(100, 31);
    defer c.deinit();
    try c.sync(d);
    try d.ok(&d.owner, "pane.float", "{\"window\":\"w0\",\"argv\":[\"true\"],\"title\":\"logs\"}");
    try c.sync(d);
    // Shown and not focused: listed like a tile.
    try expectEqualStrings("p0", c.app.focus.?);
    {
        const st = try c.status();
        defer a.free(st);
        try expect(std.mem.indexOf(u8, st, "⊘") == null);
        try expectEqual(@as(usize, 3), std.mem.count(u8, st, "true"));
    }
    // Hidden on this client: its block stays, marked.
    try c.app.run(.{ .local = .toggle_floats });
    try expect(!c.app.visibleNow("p3"));
    {
        const st = try c.status();
        defer a.free(st);
        try expect(std.mem.indexOf(u8, st, "⊘ true") != null);
        try expectEqual(@as(usize, 3), std.mem.count(u8, st, "true"));
    }
    // Another window's floats are not listed.
    try c.app.run(.{ .local = .window_next });
    {
        const st = try c.status();
        defer a.free(st);
        try expect(std.mem.indexOf(u8, st, "⊘") == null);
    }
}
