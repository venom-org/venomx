//! Key table conformance cases. A real `Product`
//! and dispatcher run in process; presentation clients are `attach` Apps
//! fed the daemon's own event log and verb replies, so the data path is the
//! one a real client sees.
const std = @import("std");
const proto = @import("proto");
const cfg = @import("cfg");
const cli = @import("cli");
const g = proto.grants;
const manifest = @import("manifest.zig");
const keys = @import("keys.zig");
const keys_registry = @import("keys_registry.zig");
const exec = @import("attach_exec.zig");
const harness = @import("chrome_tests.zig");
const Daemon = harness.Daemon;
const Client = harness.Client;
const App = @import("attach_app.zig").App;
const PaneView = @import("attach_app.zig").PaneView;
const Vt = @import("vt").Vt;
const s = @import("stream.zig");
const a = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const Value = std.json.Value;
const layout_axis = @import("layout.zig").Axis;

/// Answer the client's queued requests through the daemon under `conn`,
/// feeding each reply back to the client (config.get is not served by this
/// harness and keeps the defaults).
fn answer(d: *Daemon, conn: *proto.Connection, app: *App) !void {
    while (app.requests.items.len > 0) {
        const reqs = try app.requests.toOwnedSlice(a);
        defer a.free(reqs);
        for (reqs) |r| {
            defer a.free(r.params);
            if (std.mem.eql(u8, r.verb, "config.get")) continue;
            conn.output.clearRetainingCapacity();
            conn.sent = 0;
            const line = try std.fmt.allocPrint(a, "{{\"id\":{d},\"verb\":\"{s}\",\"params\":{s}}}", .{ r.id, r.verb, r.params });
            defer a.free(line);
            try d.dispatcher.message(conn, .{ .ndjson = line });
            try app.control(std.mem.trimEnd(u8, conn.output.items, "\n"));
        }
    }
}
/// Answer only the oldest queued request.
fn answerFirst(d: *Daemon, conn: *proto.Connection, app: *App) !void {
    const r = app.requests.orderedRemove(0);
    defer a.free(r.params);
    conn.output.clearRetainingCapacity();
    conn.sent = 0;
    const line = try std.fmt.allocPrint(a, "{{\"id\":{d},\"verb\":\"{s}\",\"params\":{s}}}", .{ r.id, r.verb, r.params });
    defer a.free(line);
    try d.dispatcher.message(conn, .{ .ndjson = line });
    try app.control(std.mem.trimEnd(u8, conn.output.items, "\n"));
}
/// The popup row that starts with these keys.
fn popupRow(model: @import("term_chrome").leader_popup.Model, key: []const u8) ?@import("term_chrome").leader_popup.Row {
    for (model.rows) |r| {
        if (std.mem.eql(u8, r.keys, key) or (std.mem.startsWith(u8, r.keys, key) and r.keys[key.len] == ' ')) return r;
    }
    return null;
}
fn errorCode(d: *Daemon, conn: *proto.Connection, verb: []const u8, params: []const u8) ![]u8 {
    var r = try d.call(conn, verb, params);
    defer r.deinit();
    const e = r.value.object.get("error") orelse return a.dupe(u8, "ok");
    return a.dupe(u8, e.object.get("code").?.string);
}
fn expectCode(d: *Daemon, conn: *proto.Connection, verb: []const u8, params: []const u8, want: []const u8) !void {
    const got = try errorCode(d, conn, verb, params);
    defer a.free(got);
    try expectEqualStrings(want, got);
}
/// Make a client's shown panes accept input without real pane streams.
fn live(app: *App, id: []const u8, modes: []const u8) !void {
    const p = app.pane(id).?;
    for (p.stream.outbox.items) |o| o.deinit(a);
    p.stream.outbox.clearRetainingCapacity();
    if (p.stream.vt == null) p.stream.vt = try Vt.init(a, .{ .cols = 40, .rows = 10 });
    try p.stream.vt.?.feed(modes);
    p.stream.pane_size = .{ .cols = p.stream.vt.?.size().cols, .rows = p.stream.vt.?.size().rows };
    p.stream.phase = .live;
    p.stream.writer = true;
}
fn takeInput(p: *PaneView) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(a);
    for (p.stream.outbox.items) |o| {
        if (o.kind == s.Kind.input) try bytes.appendSlice(a, o.payload);
        o.deinit(a);
    }
    p.stream.outbox.clearRetainingCapacity();
    return bytes.toOwnedSlice(a);
}
fn expectInput(p: *PaneView, want: []const u8) !void {
    const got = try takeInput(p);
    defer a.free(got);
    if (!std.mem.eql(u8, want, got)) std.debug.print("WANT {any}\nGOT  {any}\n", .{ want, got });
    try expectEqualStrings(want, got);
}
/// What a terminal would send a program in `modes` for the host `bytes`.
fn reference(modes: []const u8, bytes: []const u8) ![]u8 {
    var vt = try Vt.init(a, .{ .cols = 40, .rows = 10 });
    defer vt.deinit();
    try vt.feed(modes);
    var input: @import("venom-term").Input = .{};
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var rest = bytes;
    while (rest.len > 0) {
        const r = try input.parse(rest);
        if (r.event) |e| if (e == .key) {
            const enc = try vt.encodeKey(a, e.key);
            defer a.free(enc);
            try out.appendSlice(a, enc);
        };
        rest = rest[r.consumed..];
    }
    return out.toOwnedSlice(a);
}

const venom_table =
    \\{"name":"venom","prefix":"a","when":[{"key":"thread","value":"t7"}],"bindings":[
    \\ {"key":"a","exec":["venom","approve","--pane","{pane}"]},
    \\ {"key":"s","verb":"pane.attention","args":"{\"pane\":\"{pane}\",\"clear\":true}"}]}
;

test "with two Claude-Code-like panes every key except the leader reaches the focused pane unchanged, including ctrl+a and shift+tab" {
    const d = try Daemon.create();
    defer d.destroy();
    try harness.topology(d);
    // venom registers its table: products never take unprefixed keys.
    const venom = try d.principal(&.{ .{ .right = .write, .scope = "*" }, .{ .right = .read, .scope = "*" } }, "venom");
    var vconn = d.connection(venom);
    defer vconn.deinit();
    try d.ok(&vconn, "keys.register", venom_table);
    var c = try Client.init(80, 24);
    defer c.deinit();
    try c.sync(d);
    try c.app.requestKeys();
    try answer(d, &d.owner, &c.app);
    try expectEqual(@as(usize, 2), c.app.keymap.tables.len);
    // p0 is a legacy-input program; p1 enables the Kitty keyboard protocol
    // (disambiguate), as agent TUIs do.
    const kitty = "\x1b[>1u";
    try live(&c.app, "p0", "");
    try live(&c.app, "p1", kitty);
    const p0 = c.app.pane("p0").?;
    const p1 = c.app.pane("p1").?;
    try expectEqualStrings("p0", c.app.focus.?);
    // Legacy host input: the shell's start-of-line (ctrl+a), Claude Code's
    // mode-cycle (shift+tab), ctrl+c, Escape, arrows, alt+x, text. Claude
    // Code's background-task key is the leader, ctrl+b: see below.
    const host = "\x01\x1b[Z\x03\x1b[Ahello\x1bx\x7f\r";
    _ = try c.app.feedInput(host);
    try expectInput(p0, host);
    try expectInput(p1, "");
    // Kitty host input of the same keys reaches the pane identically.
    _ = try c.app.feedInput("\x1b[97;5u\x1b[9;2u");
    try expectInput(p0, "\x01\x1b[Z");
    // The leader is intercepted: leader tab moves this client's focus.
    _ = try c.app.feedInput("\x02\t");
    try expectInput(p0, "");
    try expectInput(p1, "");
    try expectEqualStrings("p1", c.app.focus.?);
    // The second pane receives the same keys, encoded for its own modes.
    for ([_][]const u8{ "\x01", "\x1b[Z", "\x1b[97;5u", "\x1b[9;2u", "\x03", "x" }) |keys_in| {
        _ = try c.app.feedInput(keys_in);
        const want = try reference(kitty, keys_in);
        defer a.free(want);
        try expect(want.len > 0);
        try expectInput(p1, want);
        try expectInput(p0, "");
    }
    // Leader then leader sends the leader itself (Ctrl+B, Claude Code's
    // background-task key), from legacy or Kitty host input.
    _ = try c.app.feedInput("\x02\x02");
    const ctrl_b = try reference(kitty, "\x1b[98;5u");
    defer a.free(ctrl_b);
    try expectInput(p1, ctrl_b);
    _ = try c.app.feedInput("\x1b[98;5u\x1b[98;5u");
    try expectInput(p1, ctrl_b);
    // An unbound key after the leader is consumed, never forwarded.
    _ = try c.app.feedInput("\x02y");
    try expectInput(p1, "");
    try expectEqualStrings("", c.app.message.items);
    // Lock mode: every key, the leader too, goes to the pane until the
    // unlock key (ctrl+alt+b; ESC ^B in legacy input).
    _ = try c.app.feedInput("\x02L");
    try expect(c.app.router.locked());
    const st = try c.status();
    defer a.free(st);
    try expect(std.mem.indexOf(u8, st, "LOCK") != null);
    _ = try c.app.feedInput("\x02d");
    const locked_ref = try reference(kitty, "\x02d");
    defer a.free(locked_ref);
    try expectInput(p1, locked_ref);
    try expect(c.app.quit == null);
    _ = try c.app.feedInput("\x1b\x02");
    try expect(!c.app.router.locked());
    try expectInput(p1, "");
    // By default the leader waits for the next key, and the loop need not wake.
    c.app.fixed_now = 1000;
    _ = try c.app.feedInput("\x02");
    c.app.tick();
    c.app.fixed_now = 1000 + 3600 * 1000;
    c.app.tick();
    try expect(c.app.leaderPending());
    try expectEqual(@as(?i64, null), c.app.nextWake());
    _ = try c.app.feedInput("\x1b");
    try c.app.flushEscape();
    try expect(!c.app.leaderPending());
    // A non-zero keys.timeout_ms ends leader mode without consuming more keys.
    c.app.keymap.settings.timeout_ms = 2000;
    c.app.fixed_now = 1000;
    _ = try c.app.feedInput("\x02");
    try expectEqual(@as(?i64, 3000), c.app.router.nextDeadline());
    c.app.fixed_now = 1000 + 2000;
    c.app.tick();
    try expect(!c.app.leaderPending());
    _ = try c.app.feedInput("d");
    try expect(c.app.quit == null);
    try expectInput(p1, "d");
}

test "a tag-scoped table is active only while a matching pane is focused" {
    const d = try Daemon.create();
    defer d.destroy();
    try harness.topology(d);
    const venom = try d.principal(&.{ .{ .right = .write, .scope = "*" }, .{ .right = .read, .scope = "*" } }, "venom");
    var vconn = d.connection(venom);
    try d.ok(&vconn, "keys.register", venom_table);
    try d.ok(&d.owner, "pane.tag", "{\"pane\":\"p1\",\"set\":[{\"key\":\"thread\",\"value\":\"t7\"}]}");
    var c = try Client.init(120, 24);
    defer c.deinit();
    try c.sync(d);
    try c.app.requestKeys();
    try answer(d, &d.owner, &c.app);
    try live(&c.app, "p0", "");
    try live(&c.app, "p1", "");
    // p0 has no thread tag: the venom table is not active.
    _ = try c.app.feedInput("\x02");
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    try expect(popupRow(try c.app.popupModel(arena.allocator()), "a") == null);
    _ = try c.app.feedInput("a");
    try expect(!c.app.leaderPending());
    try expectEqual(@as(usize, 0), c.app.execs.items.len);
    // Focus p1 (thread t7): the table opens under `a`.
    _ = try c.app.feedInput("\x02\t");
    try expectEqualStrings("p1", c.app.focus.?);
    _ = try c.app.feedInput("\x02");
    const opens = popupRow(try c.app.popupModel(arena.allocator()), "a").?;
    try expect(opens.more);
    try expectEqualStrings("venom", opens.label);
    _ = try c.app.feedInput("a");
    const st = try c.status();
    defer a.free(st);
    try expect(std.mem.indexOf(u8, st, "LEADER venom") != null);
    // The popup took over from the status line's old hint.
    try expect(std.mem.indexOf(u8, st, "approve") == null);
    const inside = try c.app.popupModel(arena.allocator());
    try expectEqualStrings("venomx › venom", inside.title);
    try expectEqualStrings("venom", popupRow(inside, "a").?.label);
    _ = try c.app.feedInput("a");
    try expectEqual(@as(usize, 1), c.app.execs.items.len);
    const argv = c.app.execs.items[0].argv;
    try expectEqual(@as(usize, 4), argv.len);
    try expectEqualStrings("p1", argv[3]);
    // A verb target is sent with the client's own identity and the
    // focused pane substituted as a whole value.
    _ = try c.app.feedInput("\x02as");
    var found = false;
    for (c.app.requests.items) |r| if (std.mem.eql(u8, r.verb, "pane.attention")) {
        try expectEqualStrings("{\"pane\":\"p1\",\"clear\":true}", r.params);
        found = true;
    };
    try expect(found);
    // Untagging p1 deactivates the table again.
    try d.ok(&d.owner, "pane.tag", "{\"pane\":\"p1\",\"unset\":[\"thread\"]}");
    try c.sync(d);
    _ = try c.app.feedInput("\x02a");
    try expectEqual(@as(usize, 1), c.app.execs.items.len);
    // The table goes with its connection (bind = connection).
    try d.ok(&d.owner, "pane.tag", "{\"pane\":\"p1\",\"set\":[{\"key\":\"thread\",\"value\":\"t7\"}]}");
    @import("product.zig").Product.connectionClosed(&d.product, &vconn);
    vconn.deinit();
    try c.sync(d);
    try answer(d, &d.owner, &c.app);
    try expectEqual(@as(usize, 1), c.app.keymap.tables.len);
    _ = try c.app.feedInput("\x02aa");
    try expectEqual(@as(usize, 1), c.app.execs.items.len);
}

test "keys.register: namespace, sub-prefix, conflicts, validation and shadowed" {
    const d = try Daemon.create();
    defer d.destroy();
    const grants = [_]g.Grant{ .{ .right = .write, .scope = "*" }, .{ .right = .read, .scope = "*" } };
    var vconn = d.connection(try d.principal(&grants, "venom"));
    defer vconn.deinit();
    var oconn = d.connection(try d.principal(&grants, "venom-os"));
    defer oconn.deinit();
    var reader = d.connection(try d.principal(&.{.{ .right = .read, .scope = "*" }}, "venom"));
    defer reader.deinit();
    const one = "{\"name\":\"venom\",\"prefix\":\"a\",\"bindings\":[{\"key\":\"a\",\"local\":\"zoom\"}]}";
    try expectCode(d, &vconn, "keys.register", "{\"name\":\"venom-os\",\"prefix\":\"a\",\"bindings\":[]}", "denied.namespace");
    try expectCode(d, &d.owner, "keys.register", "{\"name\":\"venomx\",\"prefix\":\"a\",\"bindings\":[]}", "denied.namespace");
    try expectCode(d, &reader, "keys.register", one, "denied.write");
    // A built-in key is never a product sub-prefix.
    try expectCode(d, &vconn, "keys.register", "{\"name\":\"venom\",\"prefix\":\"d\",\"bindings\":[]}", "conflict.key_prefix");
    try expectCode(d, &vconn, "keys.register", "{\"name\":\"venom\",\"prefix\":\"a\",\"bindings\":[{\"key\":\"a\",\"exec\":[\"venom\",\"--pane={pane}\"]}]}", "invalid_params.bindings");
    try expectCode(d, &vconn, "keys.register", "{\"name\":\"venom\",\"prefix\":\"a\",\"bindings\":[{\"key\":\"a\",\"verb\":\"no.such\"}]}", "invalid_params.bindings");
    try expectCode(d, &vconn, "keys.register", "{\"name\":\"venom\",\"prefix\":\"ctrl+\",\"bindings\":[]}", "invalid_params.bindings");
    try expectCode(d, &vconn, "keys.register", one, "ok");
    const before = d.events.entries.items.len;
    // Another product cannot take the same prefix; re-registering replaces.
    try expectCode(d, &oconn, "keys.register", "{\"name\":\"venom-os\",\"prefix\":\"a\",\"bindings\":[]}", "conflict.key_prefix");
    try expectCode(d, &vconn, "keys.register", one, "ok");
    try expect(d.events.entries.items.len > before);
    try expect(std.mem.indexOf(u8, d.events.entries.items[d.events.entries.items.len - 1].bytes, "\"keys.changed\"") != null);
    // The owner registers the `user` table.
    try expectCode(d, &d.owner, "keys.register", "{\"name\":\"user\",\"prefix\":\"u\",\"bindings\":[{\"key\":\"x\",\"local\":\"lock\"}],\"bind\":\"daemon\"}", "ok");
    var listed = try d.call(&reader, "keys.list", "{}");
    defer listed.deinit();
    const ok = listed.value.object.get("ok").?.object;
    try expectEqualStrings("ctrl+b", ok.get("leader").?.string);
    try expectEqualStrings("ctrl+alt+b", ok.get("unlock").?.string);
    try expectEqual(@as(i64, 200), ok.get("popup_delay_ms").?.integer);
    try expectEqual(@as(i64, 0), ok.get("timeout_ms").?.integer);
    try expectEqual(@as(usize, 3), ok.get("tables").?.array.items.len);
    try expectEqualStrings("builtin", ok.get("tables").?.array.items[0].object.get("layer").?.string);
    try expectCode(d, &vconn, "keys.unregister", "{\"name\":\"venom\"}", "ok");
    try expectCode(d, &vconn, "keys.unregister", "{\"name\":\"venom\"}", "not_found.key_table");
}

/// The product-layer table `name` from `keys.list`, or null.
fn registeredTable(listed: Value, name: []const u8) ?std.json.ObjectMap {
    for (listed.object.get("ok").?.object.get("tables").?.array.items) |t| {
        if (std.mem.eql(u8, t.object.get("name").?.string, name)) return t.object;
    }
    return null;
}
fn expectTable(d: *Daemon, conn: *proto.Connection, name: []const u8, present: bool) !void {
    var listed = try d.call(conn, "keys.list", "{}");
    defer listed.deinit();
    try expectEqual(present, registeredTable(listed.value, name) != null);
}
fn keysChanged(d: *Daemon, from: usize) usize {
    var n: usize = 0;
    for (d.events.entries.items[from..]) |e| n += @intFromBool(std.mem.indexOf(u8, e.bytes, "\"keys.changed\"") != null);
    return n;
}
/// A pane the owner created: its own principal, with the default rights.
fn ownerPanePrincipal(d: *Daemon) !g.Id {
    var created = try d.call(&d.owner, "session.create", "{\"name\":\"work\"}");
    created.deinit();
    var window = try d.call(&d.owner, "window.create", "{\"session\":\"s0\",\"argv\":[\"true\"]}");
    defer window.deinit();
    const id = window.value.object.get("ok").?.object.get("pane").?.string;
    const principal = d.product.pane(id).?.principal;
    // Its program may exit at any moment; keep the principal live regardless.
    d.registry.entries.items[@intCast(principal)].root = null;
    return principal;
}
/// Expire a principal the way the daemon does: `Server.poll` sweeps the
/// registry, then the product's tick drops what it held.
fn expire(d: *Daemon, id: g.Id) !void {
    d.registry.entries.items[@intCast(id)].expires = g.nowSeconds() - 1;
    d.registry.sweep(g.nowSeconds());
    try d.product.tick();
}
const write_root = [_]g.Grant{ .{ .right = .write, .scope = "server:root" }, .{ .right = .read, .scope = "*" } };

test "the owner registers table venom and preset venom.settings, and is refused venomx and venomx.x" {
    const d = try Daemon.create();
    defer d.destroy();
    // The canonical product table example.
    try expectCode(d, &d.owner, "keys.register", "{\"name\":\"venom\",\"prefix\":\"a\",\"when\":[{\"key\":\"product\",\"value\":\"venom\"}],\"bindings\":[{\"key\":\"s\",\"verb\":\"pane.popup\",\"args\":\"{\\\"preset\\\":\\\"venom.settings\\\",\\\"argv\\\":[\\\"venom\\\",\\\"settings\\\"]}\"}],\"bind\":\"daemon\"}", "ok");
    try expectCode(d, &d.owner, "floats.register", "{\"name\":\"venom.settings\",\"width\":\"80%\",\"height\":\"80%\",\"bind\":\"daemon\"}", "ok");
    {
        var listed = try d.call(&d.owner, "keys.list", "{}");
        defer listed.deinit();
        const table = registeredTable(listed.value, "venom").?;
        try expectEqualStrings("product", table.get("layer").?.string);
        try expectEqualStrings("owner", table.get("source").?.string);
    }
    try expect(d.product.floats.registeredPreset("venom.settings") != null);
    // Any other product's name works too, and the owner's own `user` still does.
    try expectCode(d, &d.owner, "keys.register", "{\"name\":\"venom-os\",\"prefix\":\"y\",\"bindings\":[]}", "ok");
    try expectCode(d, &d.owner, "keys.register", "{\"name\":\"user\",\"prefix\":\"u\",\"bindings\":[]}", "ok");
    try expectCode(d, &d.owner, "floats.register", "{\"name\":\"user.mine\",\"width\":\"50%\"}", "ok");
    // The reserved names stay refused.
    try expectCode(d, &d.owner, "keys.register", "{\"name\":\"venomx\",\"prefix\":\"m\",\"bindings\":[]}", "denied.namespace");
    try expectCode(d, &d.owner, "keys.unregister", "{\"name\":\"venomx\"}", "denied.namespace");
    try expectCode(d, &d.owner, "floats.register", "{\"name\":\"venomx.x\",\"width\":\"50%\"}", "denied.namespace");
    try expect(d.product.floats.registeredPreset("venomx.x") == null);
    // The owner may unregister any name, whoever registered it.
    var venom = d.connection(try d.principal(&write_root, "venom-os"));
    defer venom.deinit();
    try expectCode(d, &venom, "keys.register", "{\"name\":\"venom-os\",\"prefix\":\"y\",\"bindings\":[]}", "ok");
    try expectCode(d, &d.owner, "keys.unregister", "{\"name\":\"venom-os\"}", "ok");
    try expectCode(d, &d.owner, "keys.unregister", "{\"name\":\"venom\"}", "ok");
    try expectCode(d, &d.owner, "keys.unregister", "{\"name\":\"venom\"}", "not_found.key_table");
}

test "a pane and another namespace's principal are denied table venom; a pane the owner created gains nothing" {
    const d = try Daemon.create();
    defer d.destroy();
    const table = "{\"name\":\"venom\",\"prefix\":\"a\",\"bindings\":[]}";
    const preset = "{\"name\":\"venom.settings\",\"width\":\"50%\"}";
    // Another namespace, with write on server:root.
    var other = d.connection(try d.principal(&write_root, "venom-os"));
    defer other.deinit();
    try expectCode(d, &other, "keys.register", table, "denied.namespace");
    try expectCode(d, &other, "floats.register", preset, "denied.namespace");
    // A pane the owner created, with its default rights.
    const pane_id = try ownerPanePrincipal(d);
    try expect(pane_id != g.owner);
    var pane = d.connection(pane_id);
    defer pane.deinit();
    try expectCode(d, &pane, "keys.register", table, "denied.write");
    try expectCode(d, &pane, "floats.register", preset, "denied.write");
    // The pane reads as the owner's namespace, and gains
    // nothing even with write on server:root: the rule tests the principal.
    try expectEqualStrings(g.owner_namespace, d.registry.namespaceOf(pane_id));
    d.registry.entries.items[@intCast(pane_id)].grants = &write_root;
    try expectCode(d, &pane, "keys.register", table, "denied.namespace");
    try expectCode(d, &pane, "keys.register", "{\"name\":\"user\",\"prefix\":\"u\",\"bindings\":[]}", "denied.namespace");
    try expectCode(d, &pane, "keys.register", "{\"name\":\"venomx\",\"prefix\":\"m\",\"bindings\":[]}", "denied.namespace");
    try expectCode(d, &pane, "floats.register", preset, "denied.namespace");
    try expectCode(d, &pane, "floats.register", "{\"name\":\"user.mine\",\"width\":\"50%\"}", "denied.namespace");
    // Nor may either of them remove the owner's table.
    try expectCode(d, &d.owner, "keys.register", table, "ok");
    try expectCode(d, &other, "keys.unregister", "{\"name\":\"venom\"}", "denied.namespace");
    try expectCode(d, &pane, "keys.unregister", "{\"name\":\"venom\"}", "denied.namespace");
    try expectTable(d, &d.owner, "venom", true);
    try expect(d.product.floats.registeredPreset("venom.settings") == null);
}

test "with bind=daemon a short-lived principal's table goes when it expires; an owner-registered one stays" {
    const d = try Daemon.create();
    defer d.destroy();
    const id = try d.principal(&write_root, "venom-os");
    var short = d.connection(id);
    defer short.deinit();
    try expectCode(d, &short, "keys.register", "{\"name\":\"venom-os\",\"prefix\":\"y\",\"bindings\":[],\"bind\":\"daemon\"}", "ok");
    try expectCode(d, &short, "floats.register", "{\"name\":\"venom-os.launcher\",\"width\":\"50%\",\"bind\":\"daemon\"}", "ok");
    try expectCode(d, &d.owner, "keys.register", "{\"name\":\"venom\",\"prefix\":\"a\",\"bindings\":[],\"bind\":\"daemon\"}", "ok");
    try expectCode(d, &d.owner, "floats.register", "{\"name\":\"venom.settings\",\"width\":\"80%\",\"bind\":\"daemon\"}", "ok");
    // Nothing goes before the principal expires.
    try d.product.tick();
    try expectTable(d, &d.owner, "venom-os", true);
    try expect(d.product.floats.registeredPreset("venom-os.launcher") != null);
    const before = d.events.entries.items.len;
    try expire(d, id);
    try expectTable(d, &d.owner, "venom-os", false);
    try expect(d.product.floats.registeredPreset("venom-os.launcher") == null);
    try expectEqual(@as(usize, 1), keysChanged(d, before));
    try expectTable(d, &d.owner, "venom", true);
    try expect(d.product.floats.registeredPreset("venom.settings") != null);
}

test "a second keys.register replaces the whole table: bindings gone, source is the second caller, keys.changed once" {
    const d = try Daemon.create();
    defer d.destroy();
    const id = try d.principal(&write_root, "venom");
    var venom = d.connection(id);
    defer venom.deinit();
    try expectCode(d, &d.owner, "keys.register", "{\"name\":\"venom\",\"prefix\":\"a\",\"bindings\":[{\"key\":\"s\",\"local\":\"zoom\"},{\"key\":\"t\",\"local\":\"lock\"}],\"bind\":\"daemon\"}", "ok");
    const before = d.events.entries.items.len;
    try expectCode(d, &venom, "keys.register", "{\"name\":\"venom\",\"prefix\":\"a\",\"bindings\":[{\"key\":\"x\",\"local\":\"zoom\"}],\"bind\":\"daemon\"}", "ok");
    try expectEqual(@as(usize, 1), keysChanged(d, before));
    {
        var listed = try d.call(&d.owner, "keys.list", "{}");
        defer listed.deinit();
        const table = registeredTable(listed.value, "venom").?;
        const bindings = table.get("bindings").?.array.items;
        try expectEqual(@as(usize, 1), bindings.len);
        try expectEqualStrings("x", bindings[0].object.get("key").?.string);
        var buf: [24]u8 = undefined;
        try expectEqualStrings(g.name(id, &buf), table.get("source").?.string);
    }
    // The other way round: the owner's replacement narrows the table and
    // takes it out of the principal's lifetime.
    const again = d.events.entries.items.len;
    try expectCode(d, &d.owner, "keys.register", "{\"name\":\"venom\",\"prefix\":\"v\",\"bindings\":[],\"bind\":\"daemon\"}", "ok");
    try expectEqual(@as(usize, 1), keysChanged(d, again));
    {
        var listed = try d.call(&d.owner, "keys.list", "{}");
        defer listed.deinit();
        const table = registeredTable(listed.value, "venom").?;
        try expectEqual(@as(usize, 0), table.get("bindings").?.array.items.len);
        try expectEqualStrings("owner", table.get("source").?.string);
        try expectEqualStrings("v", table.get("prefix").?.string);
    }
    try expire(d, id);
    try expectTable(d, &d.owner, "venom", true);
}

test "a principal that replaces an owner-registered table takes its lifetime, and presets follow" {
    const d = try Daemon.create();
    defer d.destroy();
    const id = try d.principal(&write_root, "venom");
    var venom = d.connection(id);
    defer venom.deinit();
    try expectCode(d, &d.owner, "keys.register", "{\"name\":\"venom\",\"prefix\":\"a\",\"bindings\":[],\"bind\":\"daemon\"}", "ok");
    try expectCode(d, &d.owner, "floats.register", "{\"name\":\"venom.settings\",\"width\":\"80%\",\"bind\":\"daemon\"}", "ok");
    try expectCode(d, &venom, "keys.register", "{\"name\":\"venom\",\"prefix\":\"a\",\"bindings\":[],\"bind\":\"daemon\"}", "ok");
    try expectCode(d, &venom, "floats.register", "{\"name\":\"venom.settings\",\"width\":\"50%\",\"bind\":\"daemon\"}", "ok");
    try expire(d, id);
    try expectTable(d, &d.owner, "venom", false);
    try expect(d.product.floats.registeredPreset("venom.settings") == null);
}

/// A client on one window of two panes side by side (p0, p1), with p0 focused
/// and the daemon's key tables applied.
fn leaderClient(d: *Daemon, cols: u16) !Client {
    try harness.topology(d);
    var c = try Client.init(cols, 24);
    errdefer c.deinit();
    try c.sync(d);
    try c.app.requestKeys();
    try answer(d, &d.owner, &c.app);
    try live(&c.app, "p0", "");
    try live(&c.app, "p1", "");
    try expectEqualStrings("p0", c.app.focus.?);
    return c;
}
fn tickAt(app: *App, now: i64) void {
    app.fixed_now = now;
    app.tick();
}

test "a key within the delay runs with no popup; otherwise the popup appears, stays and lists active tables with labels and groups" {
    const d = try Daemon.create();
    defer d.destroy();
    // `when` matches nothing yet; `plain` is always active.
    try expectCode(d, &d.owner, "keys.register", "{\"name\":\"venom\",\"prefix\":\"v\",\"label\":\"venom\",\"when\":[{\"key\":\"thread\",\"value\":\"t7\"}],\"bindings\":[{\"key\":\"s\",\"label\":\"settings\",\"local\":\"zoom\"}],\"bind\":\"daemon\"}", "ok");
    try expectCode(d, &d.owner, "keys.register", "{\"name\":\"plain\",\"prefix\":\"y\",\"label\":\"tools\",\"groups\":[{\"key\":\"a\",\"label\":\"agents\"}],\"bindings\":[{\"key\":\"a s\",\"label\":\"stop\",\"local\":\"zoom\"},{\"key\":\"u\",\"local\":\"lock\"}],\"bind\":\"daemon\"}", "ok");
    var c = try leaderClient(d, 120);
    defer c.deinit();
    const delay = keys.default_settings.popup_delay_ms;
    try expectEqual(@as(u32, 200), delay);
    // Faster than the delay: `tab` runs and nothing was ever drawn.
    tickAt(&c.app, 1000);
    _ = try c.app.feedInput("\x02");
    tickAt(&c.app, 1000);
    try expectEqual(@as(?i64, 1000 + delay), c.app.nextWake());
    tickAt(&c.app, 1000 + delay - 1);
    try expect(!c.app.popup.visible());
    _ = try c.app.feedInput("\t");
    tickAt(&c.app, 1000 + delay + 1000);
    try expect(!c.app.popup.visible());
    try expectEqual(@as(?i64, null), c.app.nextWake());
    const none = try c.screen();
    defer a.free(none);
    try expect(std.mem.indexOf(u8, none, "send-leader") == null);
    try expectEqualStrings("p1", c.app.focus.?);
    // Slower: it comes up by itself, then stays until a key, with no wakeups.
    tickAt(&c.app, 5000);
    _ = try c.app.feedInput("\x02");
    tickAt(&c.app, 5000);
    c.app.dirty = false;
    tickAt(&c.app, 5000 + delay);
    try expect(c.app.popup.visible() and c.app.dirty);
    try expectEqual(@as(?i64, null), c.app.nextWake());
    tickAt(&c.app, 5000 + delay + 3600 * 1000);
    try expect(c.app.popup.visible() and c.app.leaderPending());
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const root = try c.app.popupModel(arena.allocator());
    try expectEqualStrings("venomx", root.title);
    try expect(popupRow(root, "v") == null); // not active
    try expectEqualStrings("tools", popupRow(root, "y").?.label);
    try expect(popupRow(root, "y").?.more);
    try expectEqualStrings("send-leader", popupRow(root, "ctrl+b").?.label);
    try expectEqualStrings("clear-selection", popupRow(root, "esc").?.label);
    const shown = try c.screen();
    defer a.free(shown);
    try expect(std.mem.indexOf(u8, shown, "╭ venomx") != null);
    try expect(std.mem.indexOf(u8, shown, "send-leader") != null);
    // Down a level it stays up at once, with the group's label.
    _ = try c.app.feedInput("y");
    tickAt(&c.app, 5000 + delay + 3600 * 1000 + 1);
    try expect(c.app.popup.visible());
    const level = try c.app.popupModel(arena.allocator());
    try expectEqualStrings("venomx › tools", level.title);
    try expectEqualStrings("agents", popupRow(level, "a").?.label);
    try expect(popupRow(level, "a").?.more);
    try expectEqualStrings("lock", popupRow(level, "u").?.label);
    _ = try c.app.feedInput("a");
    tickAt(&c.app, 5000 + delay + 3600 * 1000 + 2);
    try expectEqualStrings("venomx › tools › agents", (try c.app.popupModel(arena.allocator())).title);
    // A tag activates the table on the next leader.
    _ = try c.app.feedInput("\x1b");
    try c.app.flushEscape();
    tickAt(&c.app, 9000);
    try expect(!c.app.popup.visible());
    try d.ok(&d.owner, "pane.tag", "{\"pane\":\"p1\",\"set\":[{\"key\":\"thread\",\"value\":\"t7\"}]}");
    try c.sync(d);
    _ = try c.app.feedInput("\x02");
    tickAt(&c.app, 9000);
    tickAt(&c.app, 9000 + 200);
    try expect(c.app.popup.visible() and c.app.leaderPending());
    try expectEqualStrings("venom", popupRow(try c.app.popupModel(arena.allocator()), "v").?.label);
}

test "esc cancels, backspace goes up a level, and an unbound key reaches neither the pane nor a binding" {
    const d = try Daemon.create();
    defer d.destroy();
    try expectCode(d, &d.owner, "keys.register", "{\"name\":\"plain\",\"prefix\":\"y\",\"bindings\":[{\"key\":\"a s\",\"local\":\"zoom\"}],\"bind\":\"daemon\"}", "ok");
    var c = try leaderClient(d, 120);
    defer c.deinit();
    const p0 = c.app.pane("p0").?;
    // `esc` from the root, one byte at a time as a terminal sends it.
    _ = try c.app.feedInput("\x02");
    try expectEqual(@as(usize, 0), try c.app.feedInput("\x1b"));
    try c.app.flushEscape();
    try expect(!c.app.leaderPending());
    // `esc` from two levels down.
    _ = try c.app.feedInput("\x02ya");
    try expectEqual(@as(usize, 2), @as(usize, c.app.router.seq.len));
    try c.app.flushEscape();
    try expect(!c.app.leaderPending());
    // `backspace` up one level at a time, then out from the root.
    _ = try c.app.feedInput("\x02ya\x7f");
    try expectEqual(@as(usize, 1), @as(usize, c.app.router.seq.len));
    _ = try c.app.feedInput("\x7f");
    try expectEqual(@as(usize, 0), @as(usize, c.app.router.seq.len));
    try expect(c.app.leaderPending());
    _ = try c.app.feedInput("\x7f");
    try expect(!c.app.leaderPending());
    // Unbound at the root and under a prefix: swallowed, with no message.
    _ = try c.app.feedInput("\x02?");
    try c.app.flushEscape();
    for ([_][]const u8{ "\x02Y", "\x02yq", "\x02yaq" }) |bytes| {
        _ = try c.app.feedInput(bytes);
        try expect(!c.app.leaderPending());
        try expectInput(p0, "");
        try expectEqual(@as(usize, 0), c.app.requests.items.len);
        try expectEqualStrings("", c.app.message.items);
        try expect(c.app.zoom == null);
    }
    // After a cancel, keys go to the pane again.
    _ = try c.app.feedInput("y");
    try expectInput(p0, "y");
    // `esc` clears this client's selection from any level. The root runs
    // its `escape` binding; below it the router only cancels.
    const select = struct {
        fn f(p: *PaneView) void {
            p.selection = .{ .epoch = 0, .anchor = .{ .row = 0, .col = 0 }, .head = .{ .row = 0, .col = 1 } };
        }
    }.f;
    for ([_][]const u8{ "\x02", "\x02y", "\x02[", "\x02[k" }) |bytes| {
        select(p0);
        _ = try c.app.feedInput(bytes);
        try expect(c.app.leaderPending() and p0.selection != null);
        try c.app.flushEscape();
        try expect(!c.app.leaderPending());
        try expect(p0.selection == null);
    }
    // `backspace` and an unbound key leave it alone.
    select(p0);
    _ = try c.app.feedInput("\x02\x7f\x02Y");
    try expect(p0.selection != null);
}

test "h j k l and the arrows move focus alike and share popup rows; a sticky group stays until esc" {
    const d = try Daemon.create();
    defer d.destroy();
    try harness.topology(d);
    // p0 on the left; p1 above p3 on the right.
    try d.ok(&d.owner, "pane.split", "{\"pane\":\"p1\",\"axis\":\"rows\",\"argv\":[\"true\"]}");
    var c = try Client.init(121, 24);
    defer c.deinit();
    try c.sync(d);
    try c.app.requestKeys();
    try answer(d, &d.owner, &c.app);
    for ([_][]const u8{ "p0", "p1", "p3" }) |id| try live(&c.app, id, "");
    const legacy = [4][]const u8{ "h", "j", "k", "l" };
    const arrows = [4][]const u8{ "\x1b[D", "\x1b[B", "\x1b[A", "\x1b[C" };
    const kitty = [4][]const u8{ "\x1b[1;1D", "\x1b[1;1B", "\x1b[1;1A", "\x1b[1;1C" };
    for ([_]*const [4][]const u8{ &legacy, &arrows, &kitty }) |k| {
        const press = struct {
            fn f(app: *App, key: []const u8) !void {
                _ = try app.feedInput("\x02");
                _ = try app.feedInput(key);
            }
        }.f;
        const left, const down, const up, const right = k.*;
        // Back to p0 from wherever the last round ended.
        try press(&c.app, left);
        try expectEqualStrings("p0", c.app.focus.?);
        // An edge keeps focus.
        try press(&c.app, left);
        try expectEqualStrings("p0", c.app.focus.?);
        try press(&c.app, up);
        try expectEqualStrings("p0", c.app.focus.?);
        try press(&c.app, right);
        try expectEqualStrings("p1", c.app.focus.?);
        try press(&c.app, down);
        try expectEqualStrings("p3", c.app.focus.?);
        try press(&c.app, up);
        try expectEqualStrings("p1", c.app.focus.?);
        for ([_][]const u8{ "p0", "p1", "p3" }) |id| try expectInput(c.app.pane(id).?, "");
    }
    // Moving out of a zoomed pane ends the zoom, since the target would be hidden.
    _ = try c.app.feedInput("\x02z\x02h");
    try expectEqualStrings("p0", c.app.focus.?);
    try expect(c.app.zoom == null);
    // One popup row per direction, in the built-in table's order.
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    _ = try c.app.feedInput("\x02");
    const root = try c.app.popupModel(arena.allocator());
    try expectEqualStrings("h ←", root.rows[0].keys);
    try expectEqualStrings("focus-left", root.rows[0].label);
    try expectEqualStrings("j ↓", root.rows[1].keys);
    try expectEqualStrings("k ↑", root.rows[2].keys);
    try expectEqualStrings("l →", root.rows[3].keys);
    try expectEqualStrings("scroll", popupRow(root, "[").?.label);
    try expect(popupRow(root, "[").?.more);
    // `↑` and `↓` no longer scroll directly, and the old keys are gone.
    for ([_][]const u8{ "o", "O", "%", "\"", "v", "m" }) |key| try expect(popupRow(root, key) == null);
    try c.app.flushEscape();
    // A sticky group: scroll, stay, popup down; `?` shows it; `esc` ends it.
    const p0 = c.app.pane("p0").?;
    for (0..30) |_| try p0.stream.vt.?.feed("line\r\n");
    const top = struct {
        fn f(p: *const PaneView) u64 {
            return p.scroll orelse std.math.maxInt(u64);
        }
    }.f;
    tickAt(&c.app, 1000);
    _ = try c.app.feedInput("\x02[");
    tickAt(&c.app, 1000);
    try expect(c.app.router.stickyGroup() != null);
    tickAt(&c.app, 1000 + 200);
    try expect(c.app.popup.visible());
    try expectEqualStrings("venomx › scroll", (try c.app.popupModel(arena.allocator())).title);
    try expectEqualStrings("j ↓", (try c.app.popupModel(arena.allocator())).rows[0].keys);
    _ = try c.app.feedInput("k");
    tickAt(&c.app, 1201);
    const after_k = top(p0);
    try expect(p0.scroll != null);
    try expect(c.app.leaderPending() and !c.app.popup.visible());
    const st = try c.status();
    defer a.free(st);
    try expect(std.mem.indexOf(u8, st, "LEADER scroll") != null);
    tickAt(&c.app, 9000);
    try expect(!c.app.popup.visible());
    _ = try c.app.feedInput("\x1b[A"); // the arrow scrolls too
    try expectEqual(after_k - 1, top(p0));
    _ = try c.app.feedInput("\x1b[B");
    try expectEqual(after_k, top(p0));
    _ = try c.app.feedInput("?");
    tickAt(&c.app, 9001);
    try expect(c.app.popup.visible() and c.app.leaderPending());
    try c.app.flushEscape();
    tickAt(&c.app, 9002);
    try expect(!c.app.leaderPending() and !c.app.popup.visible());
    try expectEqual(after_k, top(p0));
    try expectInput(p0, "");
    // An unbound key ends the group too, and is swallowed.
    _ = try c.app.feedInput("\x02[q");
    try expect(!c.app.leaderPending());
    try expectInput(p0, "");
}

test "in the scroll group } and { jump between OSC 133 A prompt rows; with no marks both do nothing and the group stays" {
    const d = try Daemon.create();
    defer d.destroy();
    var c = try leaderClient(d, 120);
    defer c.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const p0 = c.app.pane("p0").?;
    const vt = p0.stream.vt.?;
    // The popup lists both keys in the scroll group.
    _ = try c.app.feedInput("\x02[");
    tickAt(&c.app, 1000);
    tickAt(&c.app, 1000 + 200);
    const model = try c.app.popupModel(arena.allocator());
    try expect(popupRow(model, "{") != null and popupRow(model, "}") != null);
    // No marks: nothing moves and the group is still active.
    _ = try c.app.feedInput("}");
    _ = try c.app.feedInput("{");
    try expect(p0.scroll == null);
    try expect(c.app.router.stickyGroup() != null);
    try c.app.flushEscape();
    // Three prompts, spaced out, then enough output to push them into scrollback.
    for (0..3) |i| {
        _ = i;
        try vt.feed("\x1b]133;A\x07$ cmd\r\n");
        for (0..4) |_| try vt.feed("out\r\n");
    }
    for (0..20) |_| try vt.feed("tail\r\n");
    const e = vt.rows().epoch;
    const first = vt.rows().oldest;
    try expectEqual(Vt.RowPrompt.start, try vt.rowPrompt(e, first));
    const second = (try vt.nextPromptRow(e, first)).?;
    const third = (try vt.nextPromptRow(e, second)).?;
    try expect(second > first and third > second);
    // `{` from the live view goes to the last prompt row above it, at the top.
    _ = try c.app.feedInput("\x02[{");
    try expectEqual(third, p0.scroll.?);
    _ = try c.app.feedInput("{");
    try expectEqual(second, p0.scroll.?);
    _ = try c.app.feedInput("{");
    try expectEqual(first, p0.scroll.?);
    // Past the first mark: nothing, and the group stays.
    _ = try c.app.feedInput("{");
    try expectEqual(first, p0.scroll.?);
    try expect(c.app.router.stickyGroup() != null);
    _ = try c.app.feedInput("}");
    try expectEqual(second, p0.scroll.?);
    _ = try c.app.feedInput("}");
    _ = try c.app.feedInput("}");
    try expectEqual(third, p0.scroll.?);
    try expectInput(p0, "");
    // `}` past the last mark does nothing.
    _ = try c.app.feedInput("}");
    try expectEqual(third, p0.scroll.?);
    // A prompt in the live area: `}` onto it returns to the live view.
    try vt.feed("\x1b]133;A\x07$ ");
    _ = try c.app.feedInput("}");
    try expect(p0.scroll == null);
}

test "{ reaches a prompt in the cropped active rows of a short pane" {
    const d = try Daemon.create();
    defer d.destroy();
    var c = try leaderClient(d, 120);
    defer c.deinit();
    const p0 = c.app.pane("p0").?;
    const vt = p0.stream.vt.?;
    p0.rect.height = 3;
    // Older prompt, then a prompt followed by more lines than the pane shows.
    try vt.feed("\x1b]133;A\x07$ old\r\n");
    for (0..12) |_| try vt.feed("x\r\n");
    try vt.feed("\x1b]133;A\x07$ new\r\n");
    for (0..8) |_| try vt.feed("y\r\n");
    const e = vt.rows().epoch;
    const live_top = c.app.topRow(p0);
    const new = (try vt.prevPromptRow(e, live_top)).?;
    const old = (try vt.prevPromptRow(e, new)).?;
    // The view is cropped, and the newer prompt is above its top.
    try expect(live_top > vt.rows().active and new < live_top);
    _ = try c.app.feedInput("\x02[{");
    try expectEqual(new, p0.scroll.?);
    _ = try c.app.feedInput("{");
    try expectEqual(old, p0.scroll.?);
    // `}` comes back down to it; past the last mark it stays.
    _ = try c.app.feedInput("}");
    try expectEqual(new, p0.scroll.?);
    _ = try c.app.feedInput("}");
    try expectEqual(new, p0.scroll.?);
}

fn keysRow(app: *const App, id: []const u8) ?[]const u8 {
    for (app.picker.?.items.items) |i| if (std.mem.eql(u8, i.id, id)) return i.label;
    return null;
}

test "leader ? lists every active key; typing filters fuzzily, enter types the keys, esc closes" {
    const d = try Daemon.create();
    defer d.destroy();
    try expectCode(d, &d.owner, "keys.register", "{\"name\":\"venom\",\"prefix\":\"v\",\"label\":\"venom\",\"bindings\":[{\"key\":\"d\",\"label\":\"diff\",\"local\":\"zoom\"}],\"bind\":\"daemon\"}", "ok");
    var c = try leaderClient(d, 120);
    defer c.deinit();
    const p0 = c.app.pane("p0").?;
    // `?` from the open root popup: leader mode ends and the list opens.
    tickAt(&c.app, 1000);
    _ = try c.app.feedInput("\x02");
    tickAt(&c.app, 1000);
    tickAt(&c.app, 1300);
    try expect(c.app.popup.visible());
    _ = try c.app.feedInput("?");
    tickAt(&c.app, 1301);
    try expect(!c.app.leaderPending() and !c.app.popup.visible());
    try expect(c.app.picker.?.kind == .keys);
    try expectEqual(c.app.picker.?.items.items.len, c.app.picker.?.shown.items.len);
    // Every level and table, with the group path before the label.
    try expectEqualStrings("focus-left", keysRow(&c.app, "h").?);
    try expectEqualStrings("resize › resize-left", keysRow(&c.app, "r h").?);
    try expectEqualStrings("scroll › scroll-line-up", keysRow(&c.app, "[ k").?);
    try expectEqualStrings("venom › diff", keysRow(&c.app, "v d").?);
    try expectEqualStrings("all-keys", keysRow(&c.app, "?").?);
    try expectEqualStrings("send-leader", keysRow(&c.app, "ctrl+b").?);
    const listed = try c.screen();
    defer a.free(listed);
    try expect(std.mem.indexOf(u8, listed, "type to filter") != null);
    try expect(std.mem.indexOf(u8, listed, "focus-left") != null);
    // More rows than fit: the selection scrolls into view.
    _ = try c.app.feedInput("\x1b[A");
    try expectEqualStrings("send-leader", c.app.picker.?.current().?.label);
    const last = try c.screen();
    defer a.free(last);
    try expect(std.mem.indexOf(u8, last, "send-leader") != null);
    _ = try c.app.feedInput("\x1b[B");
    try expectEqual(@as(usize, 0), c.app.picker.?.selected);
    // Typing filters; `j`, `k` and `q` are text here, not moves.
    _ = try c.app.feedInput("venomdiff");
    try expectEqualStrings("venomdiff", c.app.picker.?.query.items);
    try expectEqualStrings("v d", c.app.picker.?.current().?.id);
    _ = try c.app.feedInput("qjk");
    try expectEqual(@as(usize, 0), c.app.picker.?.shown.items.len);
    try expect(c.app.picker.?.current() == null);
    const none = try c.screen();
    defer a.free(none);
    try expect(std.mem.indexOf(u8, none, "no match") != null);
    // Enter with nothing listed does nothing.
    _ = try c.app.feedInput("\r");
    try expect(c.app.picker != null);
    _ = try c.app.feedInput("\x7f\x7f\x7f");
    try expectEqualStrings("venomdiff", c.app.picker.?.query.items);
    try expectEqual(@as(usize, 1), c.app.picker.?.shown.items.len);
    // Terms match apart, in any field: keys or label.
    _ = try c.app.feedInput("\x15");
    try expectEqual(@as(usize, 0), c.app.picker.?.query.items.len);
    _ = try c.app.feedInput("rh left");
    try expectEqualStrings("r h", c.app.picker.?.current().?.id);
    try expectInput(p0, "");
    // Enter types the keys after the leader.
    _ = try c.app.feedInput("\x15toggle-floats\r");
    try expect(c.app.picker == null);
    try expect(c.app.floats_hidden);
    try expect(!c.app.leaderPending());
    // A sticky group's binding leaves the client in the group, popup down.
    _ = try c.app.feedInput("\x02?scroll-line-up\r");
    try expect(c.app.picker == null);
    try expect(c.app.leaderPending() and c.app.router.stickyGroup() != null);
    tickAt(&c.app, 5000);
    try expect(!c.app.popup.visible());
    try c.app.flushEscape();
    try expect(!c.app.leaderPending());
    // `esc` closes the list and sends nothing.
    _ = try c.app.feedInput("\x02?");
    try expect(c.app.picker != null);
    try c.app.flushEscape();
    try expect(c.app.picker == null);
    try expectInput(p0, "");
}

test "the built-in table: leader keys, numbered windows, close-pane, reserved sub-prefixes" {
    for (keys.reserved_prefixes) |key| try expect(!keys.builtinKey(keys.parseChord(key).?));
    const d = try Daemon.create();
    defer d.destroy();
    var c = try leaderClient(d, 120);
    defer c.deinit();
    // Products may register the reserved prefixes; a built-in key stays refused.
    try expectCode(d, &d.owner, "keys.register", "{\"name\":\"venom\",\"prefix\":\"v\",\"bindings\":[]}", "ok");
    try expectCode(d, &d.owner, "keys.register", "{\"name\":\"venom-os\",\"prefix\":\"o\",\"bindings\":[]}", "ok");
    try expectCode(d, &d.owner, "keys.register", "{\"name\":\"user\",\"prefix\":\"m\",\"bindings\":[]}", "ok");
    for ([_][]const u8{ "h", "j", "\\\\", "-", "1", "[", "X", "?" }) |key| {
        const table = try std.fmt.allocPrint(a, "{{\"name\":\"other\",\"prefix\":\"{s}\",\"bindings\":[]}}", .{key});
        defer a.free(table);
        try expectCode(d, &d.owner, "keys.register", table, "conflict.key_prefix");
    }
    // `1`-`9` pick windows in ID order, and a missing one says so.
    try expectEqualStrings("w0", c.app.active.?);
    _ = try c.app.feedInput("\x022");
    try expectEqualStrings("w1", c.app.active.?);
    _ = try c.app.feedInput("\x021");
    try expectEqualStrings("w0", c.app.active.?);
    _ = try c.app.feedInput("\x029");
    try expectEqualStrings("w0", c.app.active.?);
    try expect(std.mem.indexOf(u8, c.app.message.items, "no window 9") != null);
    // `\\` and `-` split; `X` kills and removes the focused pane.
    try live(&c.app, "p0", "");
    _ = try c.app.feedInput("\x02\\\x02-\x02X");
    try expectEqual(@as(usize, 3), c.app.requests.items.len);
    try expectEqualStrings("pane.split", c.app.requests.items[0].verb);
    try expect(std.mem.indexOf(u8, c.app.requests.items[0].params, "\"axis\":\"cols\"") != null);
    try expectEqualStrings("pane.split", c.app.requests.items[1].verb);
    try expect(std.mem.indexOf(u8, c.app.requests.items[1].params, "\"axis\":\"rows\"") != null);
    try expectEqualStrings("pane.kill", c.app.requests.items[2].verb);
    try expectEqualStrings("{\"pane\":\"p0\",\"remove\":true}", c.app.requests.items[2].params);
}

const KeysOnly = struct { keys: keys.Config = .{} };
const policies = [_]cfg.FieldPolicy{ .{ .key = "keys.tables", .by_name = true }, .{ .key = "keys.prefixes", .by_name = true } };
const KeyStore = cfg.Store(KeysOnly, &policies);
fn validateKeys(c: KeysOnly) ?cfg.Validation {
    c.keys.check() catch return .{ .key = "keys" };
    return null;
}
fn validateKeysLayer(c: KeysOnly, source: cfg.Source) ?cfg.Validation {
    return keys_registry.layerConflict(c.keys, source);
}
fn writeFile(dir: std.Io.Dir, name: []const u8, bytes: []const u8) !void {
    try dir.writeFile(std.testing.io, .{ .sub_path = name, .data = bytes });
}

test "a popup closing during leader mode hands the sequence to the pane focus returns to" {
    const d = try Daemon.create();
    defer d.destroy();
    var c = try leaderClient(d, 120);
    defer c.deinit();
    const app = &c.app;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const x = arena.allocator();
    try d.ok(&d.owner, "keys.register", "{\"name\":\"venom\",\"prefix\":\"a\",\"when\":[{\"key\":\"thread\",\"value\":\"t7\"}],\"bind\":\"daemon\",\"bindings\":[{\"key\":\"s\",\"exec\":[\"venom\",\"settings\",\"--pane\",\"{pane}\"]}]}");
    try d.ok(&d.owner, "pane.tag", "{\"pane\":\"p0\",\"set\":[{\"key\":\"thread\",\"value\":\"t7\"}]}");
    try c.sync(d);
    try answer(d, &d.owner, app);
    // A popup takes the focus, and the leader arrives before it has closed.
    try app.runTarget(.{ .verb = .{ .name = "pane.popup", .args = "{\"argv\":[\"true\"]}" } });
    try answer(d, &d.owner, app);
    try c.sync(d);
    try expectEqualStrings("p3", app.focus.?);
    _ = try app.feedInput("\x02");
    try expect(app.leaderPending());
    try expect(popupRow(try app.popupModel(x), "a") == null);
    // It closes during leader mode: the rows and the next keys are p0's.
    d.product.pane("p3").?.pane.status = .{ .code = 0 };
    try d.ok(&d.owner, "pane.remove", "{\"pane\":\"p3\"}");
    try c.sync(d);
    try expectEqualStrings("p0", app.focus.?);
    try expect(app.leaderPending() and app.dirty);
    try expectEqualStrings("venom", popupRow(try app.popupModel(x), "a").?.label);
    _ = try app.feedInput("as");
    try expect(!app.leaderPending());
    try expectEqual(@as(usize, 1), app.execs.items.len);
    try expectEqualStrings("p0", app.execs.items[0].argv[3]);
    try expectInput(app.pane("p0").?, "");

    // Focus moves to a pane without the table inside it: the typed keys no
    // longer resolve, so leader mode ends and the next key is the pane's.
    _ = try app.feedInput("\x02a");
    try expect(app.leaderPending());
    const right = app.pane("p1").?;
    const click = try std.fmt.allocPrint(x, "\x1b[<0;{d};{d}M", .{ right.rect.x + 2, right.rect.y + 2 });
    _ = try app.feedInput(click);
    try expectEqualStrings("p1", app.focus.?);
    try expect(!app.leaderPending());
    _ = try app.feedInput("s");
    try expectEqual(@as(usize, 1), app.execs.items.len);
    try expectInput(right, "s");
}

test "focus-attention in another window keeps a sticky group the final pane has, whatever its fallback pane has" {
    const d = try Daemon.create();
    defer d.destroy();
    var c = try leaderClient(d, 120);
    defer c.deinit();
    const app = &c.app;
    const tag = "\"key\":\"thread\",\"value\":\"t7\"";
    try d.ok(&d.owner, "keys.register", "{\"name\":\"t\",\"prefix\":\"q\",\"when\":[{" ++ tag ++ "}],\"bind\":\"daemon\",\"groups\":[{\"key\":\"r\",\"label\":\"go\",\"sticky\":true}],\"bindings\":[{\"key\":\"r n\",\"local\":\"focus-attention\"}]}");
    try d.ok(&d.owner, "pane.tag", "{\"pane\":\"p0\",\"set\":[{" ++ tag ++ "}]}");
    // w1's lowest pane, where focus lands first, lacks the tag; the target has it.
    try d.ok(&d.owner, "pane.split", "{\"pane\":\"p2\",\"axis\":\"cols\",\"argv\":[\"true\"]}");
    try d.ok(&d.owner, "pane.tag", "{\"pane\":\"p3\",\"set\":[{" ++ tag ++ "}]}");
    try d.ok(&d.owner, "pane.attention", "{\"pane\":\"p3\",\"level\":\"warn\"}");
    try c.sync(d);
    try answer(d, &d.owner, app);
    _ = try app.feedInput("\x02qrn");
    try expectEqualStrings("p3", app.focus.?);
    try expect(app.leaderPending());
    try expectEqualStrings("go", app.router.stickyGroup().?.label);
}

test "same-layer key conflicts fail config check (and set, reload) as invalid_params.key_conflict; cross-layer shadowing is reported by doctor" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(base);
    const user = try std.fs.path.join(a, &.{ base, "config.zon" });
    defer a.free(user);
    const defaults = try std.fs.path.join(a, &.{ base, "defaults.zon" });
    defer a.free(defaults);
    // The defaults file (venom-os) binds a sub-table under `a`; the user
    // binds `d` directly and another table under `a`.
    try writeFile(tmp.dir, "defaults.zon",
        \\.{ .keys = .{ .tables = .{ .{ .name = "distro", .prefix = "a", .bind = .{ .{ .key = "x", .local = "zoom" } } } } } }
    );
    try writeFile(tmp.dir, "config.zon",
        \\.{ .keys = .{ .leader = "ctrl+shift+a", .tables = .{
        \\    .{ .name = "mine", .bind = .{ .{ .key = "d", .local = "zoom" } } },
        \\    .{ .name = "sub", .prefix = "a", .bind = .{ .{ .key = "y", .local = "lock" } } },
        \\} } }
    );
    var store = try KeyStore.init(a, .{ .io = std.testing.io, .path = user, .defaults = &.{defaults}, .validate = validateKeys, .validate_layer = validateKeysLayer });
    defer store.deinit();
    var layers: keys_registry.KeyLayers(KeyStore) = .{ .store = &store };
    const d = try Daemon.create();
    defer d.destroy();
    d.product.keytables.source = layers.source();
    // A product table under `a` too: the user's `sub` shadows it.
    var vconn = d.connection(try d.principal(&.{ .{ .right = .write, .scope = "*" }, .{ .right = .read, .scope = "*" } }, "venom"));
    defer vconn.deinit();
    var registered = try d.call(&vconn, "keys.register", "{\"name\":\"venom\",\"prefix\":\"a\",\"bindings\":[{\"key\":\"a\",\"local\":\"zoom\"}]}");
    defer registered.deinit();
    const shadowed = registered.value.object.get("ok").?.object.get("shadowed").?.array.items;
    try expectEqual(@as(usize, 1), shadowed.len);
    try expectEqualStrings("sub", shadowed[0].object.get("by").?.string);
    try expectEqualStrings("user", shadowed[0].object.get("by_layer").?.string);
    // `config check` through the real verb: valid (different layers).
    const schema = comptime cfg.mergeWith(manifest.core_model, .{ .errors = &keys_registry.config_errors });
    const bindings = d.product.bindings() ++ .{proto.Binding{ .verb = "events", .handler = proto.VerbHandler.init(&d.events) }} ++ store.bindings();
    var dispatcher = try proto.Dispatcher.init(a, &schema, &bindings, .{}, null);
    defer dispatcher.deinit();
    const configCall = struct {
        fn f(disp: *proto.Dispatcher, conn: *proto.Connection, line: []const u8) !std.json.Parsed(Value) {
            conn.output.clearRetainingCapacity();
            conn.sent = 0;
            try disp.message(conn, .{ .ndjson = line });
            return std.json.parseFromSlice(Value, a, std.mem.trimEnd(u8, conn.output.items, "\n"), .{});
        }
    }.f;
    const checkCall = struct {
        fn f(disp: *proto.Dispatcher, conn: *proto.Connection) !std.json.Parsed(Value) {
            return configCall(disp, conn, "{\"id\":1,\"verb\":\"config.check\",\"params\":{}}");
        }
    }.f;
    const expectConflict = struct {
        fn f(r: std.json.Parsed(Value), source: []const u8) !void {
            const e = r.value.object.get("error").?.object;
            try expectEqualStrings("invalid_params.key_conflict", e.get("code").?.string);
            const data = e.get("data").?.object;
            try expectEqualStrings("keys.tables", data.get("key").?.string);
            try expectEqualStrings(source, data.get("source").?.string);
        }
    }.f;
    {
        var r = try checkCall(&dispatcher, &d.owner);
        defer r.deinit();
        try expect(r.value.object.get("ok").?.object.get("valid").?.bool);
    }
    // Doctor: shadowing warns (built-in `d`, distro and venom under `a`),
    // no conflicts, and a leader that needs the Kitty protocol warns.
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var report: cli.doctor.Report = .{ .arena = arena.allocator(), .tool = "venomx" };
    try keys_registry.doctor(&report, &d.product);
    var seen: usize = 0;
    for (report.results.items) |r| {
        if (std.mem.eql(u8, r.id, "keys.conflicts")) try expectEqual(cli.doctor.Status.ok, r.status);
        if (std.mem.eql(u8, r.id, "keys.shadowed")) {
            try expectEqual(cli.doctor.Status.warn, r.status);
            for ([_][]const u8{ "venomx \"d\"", "distro", "venom \"a a\"" }) |want| try expect(std.mem.indexOf(u8, r.message, want) != null);
        }
        if (std.mem.eql(u8, r.id, "keys.leader")) {
            try expectEqual(cli.doctor.Status.warn, r.status);
            try expect(std.mem.indexOf(u8, r.message, "Kitty") != null);
        }
        seen += 1;
    }
    try expectEqual(@as(usize, 3), seen);
    // The defaults need no keyboard protocol and doctor says what they are.
    {
        const fresh = try Daemon.create();
        defer fresh.destroy();
        var plain: cli.doctor.Report = .{ .arena = arena.allocator(), .tool = "venomx" };
        try keys_registry.doctor(&plain, &fresh.product);
        const leader = plain.results.items[2];
        try expectEqualStrings("keys.leader", leader.id);
        try expectEqual(cli.doctor.Status.ok, leader.status);
        try expectEqualStrings("leader ctrl+b, unlock ctrl+alt+b", leader.message);
    }
    // Two user tables on one sub-prefix: a same-layer conflict.
    try writeFile(tmp.dir, "config.zon",
        \\.{ .keys = .{ .tables = .{
        \\    .{ .name = "one", .prefix = "b", .bind = .{ .{ .key = "x", .local = "zoom" } } },
        \\    .{ .name = "two", .prefix = "b", .bind = .{ .{ .key = "y", .local = "lock" } } },
        \\} } }
    );
    {
        var r = try checkCall(&dispatcher, &d.owner);
        defer r.deinit();
        try expectConflict(r, "user");
    }
    // Reload rejects it too and keeps the active config.
    {
        var r = try configCall(&dispatcher, &d.owner, "{\"id\":2,\"verb\":\"config.reload\",\"params\":{}}");
        defer r.deinit();
        try expectConflict(r, "user");
        // Still distro (defaults), mine and sub (user).
        try expectEqual(@as(usize, 3), store.current().keys.tables.len);
        for (store.current().keys.tables) |t| try expect(!std.mem.eql(u8, t.name, "one"));
    }
    var report2: cli.doctor.Report = .{ .arena = arena.allocator(), .tool = "venomx" };
    try keys_registry.doctor(&report2, &d.product);
    try expectEqual(cli.doctor.Status.fail, report2.results.items[0].status);
    try expectEqualStrings("keys.conflicts", report2.results.items[0].id);
    // config set of a conflicting candidate fails and leaves the file as is.
    try writeFile(tmp.dir, "config.zon", ".{}");
    {
        var r = try configCall(&dispatcher, &d.owner, "{\"id\":3,\"verb\":\"config.set\",\"params\":{\"key\":\"keys.tables\",\"value\":\".{ .{ .name = \\\"one\\\", .prefix = \\\"b\\\", .bind = .{ .{ .key = \\\"x\\\", .local = \\\"zoom\\\" } } }, .{ .name = \\\"two\\\", .prefix = \\\"b\\\", .bind = .{ .{ .key = \\\"y\\\", .local = \\\"lock\\\" } } } }\"}}");
        defer r.deinit();
        try expectConflict(r, "user");
        const kept = try tmp.dir.readFileAlloc(std.testing.io, "config.zon", a, .limited(1 << 16));
        defer a.free(kept);
        try expectEqualStrings(".{}", kept);
    }
    // A conflict inside the defaults file is reported on defaults.
    try writeFile(tmp.dir, "defaults.zon",
        \\.{ .keys = .{ .tables = .{
        \\    .{ .name = "d1", .prefix = "c", .bind = .{ .{ .key = "x", .local = "zoom" } } },
        \\    .{ .name = "d2", .prefix = "c", .bind = .{ .{ .key = "y", .local = "lock" } } },
        \\} } }
    );
    {
        var r = try checkCall(&dispatcher, &d.owner);
        defer r.deinit();
        try expectConflict(r, "defaults");
    }
    try writeFile(tmp.dir, "defaults.zon", ".{}");
    // One table binding a key twice fails validation itself.
    try writeFile(tmp.dir, "config.zon",
        \\.{ .keys = .{ .tables = .{ .{ .name = "one", .bind = .{ .{ .key = "g", .local = "zoom" }, .{ .key = "g g", .local = "lock" } } } } } }
    );
    {
        var r = try checkCall(&dispatcher, &d.owner);
        defer r.deinit();
        try expect(r.value.object.get("error") != null);
    }
    try std.testing.expectError(error.InvalidConfig, store.check());
}

test "keys.prefixes moves a registered table, the move survives another keys.register, and keys.list shows the effective prefix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(base);
    const user = try std.fs.path.join(a, &.{ base, "config.zon" });
    defer a.free(user);
    const defaults = try std.fs.path.join(a, &.{ base, "defaults.zon" });
    defer a.free(defaults);
    // The user's entry wins per name; the defaults' other entry still applies.
    try writeFile(tmp.dir, "defaults.zon",
        \\.{ .keys = .{ .prefixes = .{ .{ .name = "venom", .prefix = "g" }, .{ .name = "venom-os", .prefix = "w" } } } }
    );
    try writeFile(tmp.dir, "config.zon",
        \\.{ .keys = .{ .prefixes = .{ .{ .name = "venom", .prefix = "a" } } } }
    );
    var store = try KeyStore.init(a, .{ .io = std.testing.io, .path = user, .defaults = &.{defaults}, .validate = validateKeys, .validate_layer = validateKeysLayer });
    defer store.deinit();
    var layers: keys_registry.KeyLayers(KeyStore) = .{ .store = &store };
    const d = try Daemon.create();
    defer d.destroy();
    d.product.keytables.source = layers.source();
    const table = "{\"name\":\"venom\",\"prefix\":\"v\",\"label\":\"venom\",\"groups\":[{\"key\":\"x\",\"label\":\"stuff\",\"sticky\":true}],\"bindings\":[{\"key\":\"x s\",\"label\":\"settings\",\"local\":\"zoom\"}],\"bind\":\"daemon\"}";
    const effective = struct {
        fn f(dm: *Daemon, name: []const u8, want: []const u8) !void {
            var listed = try dm.call(&dm.owner, "keys.list", "{}");
            defer listed.deinit();
            try expectEqualStrings(want, registeredTable(listed.value, name).?.get("prefix").?.string);
        }
    }.f;
    var first = try d.call(&d.owner, "keys.register", table);
    defer first.deinit();
    try expectEqualStrings("a", first.value.object.get("ok").?.object.get("prefix").?.string);
    try effective(d, "venom", "a");
    // The registered table keeps its label and groups.
    {
        var listed = try d.call(&d.owner, "keys.list", "{}");
        defer listed.deinit();
        const t = registeredTable(listed.value, "venom").?;
        try expectEqualStrings("venom", t.get("label").?.string);
        const g0 = t.get("groups").?.array.items[0].object;
        try expectEqualStrings("stuff", g0.get("label").?.string);
        try expect(g0.get("sticky").?.bool);
        try expectEqualStrings("settings", t.get("bindings").?.array.items[0].object.get("label").?.string);
    }
    try expectCode(d, &d.owner, "keys.register", "{\"name\":\"venom\",\"prefix\":\"v\",\"groups\":[{\"key\":\"x\",\"label\":\"nothing under it\"}],\"bindings\":[]}", "invalid_params.bindings");
    try expectCode(d, &d.owner, "keys.register", "{\"name\":\"venom\",\"prefix\":\"v\",\"label\":\"\",\"bindings\":[]}", "invalid_params.bindings");
    // Registering again, wherever it asks for, stays moved.
    try expectCode(d, &d.owner, "keys.register", table, "ok");
    try effective(d, "venom", "a");
    try expectCode(d, &d.owner, "keys.register", "{\"name\":\"venom-os\",\"prefix\":\"o\",\"bindings\":[{\"key\":\"s\",\"local\":\"zoom\"}],\"bind\":\"daemon\"}", "ok");
    try effective(d, "venom-os", "w");
    // Conflicts look at the moved prefix: `a` is taken, `v` is free again.
    try expectCode(d, &d.owner, "keys.register", "{\"name\":\"other\",\"prefix\":\"a\",\"bindings\":[]}", "conflict.key_prefix");
    // Moved by config too, a table asking for `q` is told the prefix it would get.
    try writeFile(tmp.dir, "config.zon",
        \\.{ .keys = .{ .prefixes = .{ .{ .name = "venom", .prefix = "a" }, .{ .name = "third", .prefix = "a" } } } }
    );
    _ = try store.reload();
    {
        var refused = try d.call(&d.owner, "keys.register", "{\"name\":\"third\",\"prefix\":\"q\",\"bindings\":[]}");
        defer refused.deinit();
        const e = refused.value.object.get("error").?.object;
        try expectEqualStrings("conflict.key_prefix", e.get("code").?.string);
        try expectEqualStrings("a", e.get("data").?.object.get("prefix").?.string);
        try expectEqualStrings("venom", e.get("data").?.object.get("table").?.string);
    }
    try writeFile(tmp.dir, "config.zon",
        \\.{ .keys = .{ .prefixes = .{ .{ .name = "venom", .prefix = "a" } } } }
    );
    _ = try store.reload();
    try expectCode(d, &d.owner, "keys.register", "{\"name\":\"other\",\"prefix\":\"v\",\"bindings\":[{\"key\":\"s\",\"local\":\"lock\"}],\"bind\":\"daemon\"}", "ok");
    // A client follows: the moved table opens under `a`, not `v`.
    try harness.topology(d);
    var c = try Client.init(120, 24);
    defer c.deinit();
    try c.sync(d);
    try c.app.requestKeys();
    try answer(d, &d.owner, &c.app);
    try live(&c.app, "p0", "");
    _ = try c.app.feedInput("\x02ax");
    try expect(c.app.router.stickyGroup() != null);
    try c.app.flushEscape();
    _ = try c.app.feedInput("\x02ax");
    try c.app.flushEscape();
    _ = try c.app.feedInput("\x02vq");
    try expect(!c.app.leaderPending());
    // Moving it again goes through config, with the same precedence.
    try writeFile(tmp.dir, "config.zon",
        \\.{ .keys = .{ .prefixes = .{ .{ .name = "venom", .prefix = "b" } } } }
    );
    _ = try store.reload();
    try effective(d, "venom", "b");
    // `config set` applies at once, with no reload.
    _ = try store.set("keys.leader", "\"ctrl+a\"");
    _ = try store.set("keys.timeout_ms", "500");
    _ = try store.set("keys.prefixes", ".{ .{ .name = \"venom\", .prefix = \"f\" } }");
    try effective(d, "venom", "f");
    {
        var listed = try d.call(&d.owner, "keys.list", "{}");
        defer listed.deinit();
        const ok = listed.value.object.get("ok").?.object;
        try expectEqualStrings("ctrl+a", ok.get("leader").?.string);
        try expectEqual(@as(i64, 500), ok.get("timeout_ms").?.integer);
    }
    _ = try store.set("keys.leader", "\"ctrl+b\"");
    _ = try store.set("keys.timeout_ms", "0");
    // A built-in table has no sub-prefix to move.
    try writeFile(tmp.dir, "config.zon",
        \\.{ .keys = .{ .prefixes = .{ .{ .name = "venomx", .prefix = "b" } } } }
    );
    _ = try store.reload();
    {
        var listed = try d.call(&d.owner, "keys.list", "{}");
        defer listed.deinit();
        try expect(registeredTable(listed.value, "venomx").?.get("prefix") == null);
    }
    // One file naming a table twice fails check.
    try writeFile(tmp.dir, "config.zon",
        \\.{ .keys = .{ .prefixes = .{ .{ .name = "venom", .prefix = "b" }, .{ .name = "venom", .prefix = "c" } } } }
    );
    try std.testing.expectError(error.InvalidConfig, store.check());
}

test "with the defaults, ctrl+b ctrl+b delivers ctrl+b to the focused pane, with and without the Kitty keyboard protocol" {
    const d = try Daemon.create();
    defer d.destroy();
    var c = try leaderClient(d, 120);
    defer c.deinit();
    const p0 = c.app.pane("p0").?;
    const p1 = c.app.pane("p1").?;
    // A legacy pane gets the control byte, from either kind of host.
    _ = try c.app.feedInput("\x02\x02");
    try expectInput(p0, "\x02");
    _ = try c.app.feedInput("\x1b[98;5u\x1b[98;5u");
    try expectInput(p0, "\x02");
    // A Kitty pane gets its own encoding, from either kind of host.
    try live(&c.app, "p1", "\x1b[>1u");
    _ = try c.app.feedInput("\x02\t");
    const want = try reference("\x1b[>1u", "\x1b[98;5u");
    defer a.free(want);
    _ = try c.app.feedInput("\x02\x02");
    try expectInput(p1, want);
    _ = try c.app.feedInput("\x1b[98;5u\x1b[98;5u");
    try expectInput(p1, want);
    try expectInput(p0, "");
    try expect(!c.app.leaderPending());
}

test "the popup in a frame: covered panes redraw in full, others patch, and it goes with leader mode" {
    const d = try Daemon.create();
    defer d.destroy();
    var c = try leaderClient(d, 120);
    defer c.deinit();
    const app = &c.app;
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var surface = try @import("venom-term").Surface.init(a, app.cols, app.rows);
    defer surface.deinit(&out.writer);
    try app.render(&surface);
    // A small popup: one short group, at the bottom left, over p0 only.
    try d.ok(&d.owner, "keys.register", "{\"name\":\"plain\",\"prefix\":\"y\",\"bindings\":[{\"key\":\"u\",\"local\":\"lock\"}],\"bind\":\"daemon\"}");
    try c.sync(d);
    try answer(d, &d.owner, app);
    _ = try app.feedInput("\x02y");
    tickAt(app, 1000);
    tickAt(app, 1200);
    try expect(app.popup.visible());
    try app.render(&surface);
    const left = app.pane("p0").?;
    const right = app.pane("p1").?;
    try expect(!app.dirty);
    // The covered pane cannot patch: the full render keeps the popup on top.
    try left.stream.vt.?.feed("under");
    left.damaged = true;
    app.pane_damage = true;
    try app.render(&surface);
    const covered = try surfaceText(&surface);
    defer a.free(covered);
    try expect(std.mem.indexOf(u8, covered, "venomx › plain") != null);
    try expect(std.mem.indexOf(u8, covered, "under") != null);
    // The other pane patches, and the popup is still there.
    try right.stream.vt.?.feed("clear");
    right.damaged = true;
    app.pane_damage = true;
    try app.render(&surface);
    const patched = try surfaceText(&surface);
    defer a.free(patched);
    try expect(std.mem.indexOf(u8, patched, "venomx › plain") != null);
    try expect(std.mem.indexOf(u8, patched, "clear") != null);
    // Leaving redraws what it covered.
    try app.flushEscape();
    tickAt(app, 1300);
    try expect(app.dirty);
    try app.render(&surface);
    const gone = try surfaceText(&surface);
    defer a.free(gone);
    try expect(std.mem.indexOf(u8, gone, "venomx › plain") == null);
    try expect(std.mem.indexOf(u8, gone, "under") != null);
}

test "a reload during leader mode waits for it to end, and the next key does not reach the pane" {
    const d = try Daemon.create();
    defer d.destroy();
    try d.ok(&d.owner, "keys.register", "{\"name\":\"plain\",\"prefix\":\"y\",\"bindings\":[{\"key\":\"u\",\"local\":\"zoom\"}],\"bind\":\"daemon\"}");
    var c = try leaderClient(d, 120);
    defer c.deinit();
    const app = &c.app;
    const p0 = app.pane("p0").?;
    const replace = "{\"name\":\"plain\",\"prefix\":\"y\",\"bindings\":[{\"key\":\"w\",\"local\":\"lock\"}],\"bind\":\"daemon\"}";
    // Leader mode has no timeout, so any time may pass before the reload.
    tickAt(app, 1000);
    _ = try app.feedInput("\x02");
    tickAt(app, 1000);
    tickAt(app, 1400);
    try d.ok(&d.owner, "keys.register", replace);
    try c.sync(d);
    try answer(d, &d.owner, app);
    tickAt(app, 1500);
    try expect(app.popup.visible() and app.leaderPending());
    // The old tables stand until leader mode ends, and the keys go on to them.
    _ = try app.feedInput("yu");
    try expect(app.zoom != null);
    try expectInput(p0, "");
    tickAt(app, 1600);
    _ = try app.feedInput("\x02y");
    try expect(app.next_keymap == null);
    _ = try app.feedInput("w");
    try expect(app.router.locked());
    _ = try app.feedInput("\x1b\x02");
    // Two reloads while pending: the last one wins, and nothing leaks.
    _ = try app.feedInput("\x02");
    try d.ok(&d.owner, "keys.register", "{\"name\":\"plain\",\"prefix\":\"y\",\"bindings\":[{\"key\":\"a\",\"local\":\"lock\"}],\"bind\":\"daemon\"}");
    try d.ok(&d.owner, "keys.register", "{\"name\":\"plain\",\"prefix\":\"y\",\"bindings\":[{\"key\":\"b\",\"local\":\"lock\"}],\"bind\":\"daemon\"}");
    try c.sync(d);
    try answer(d, &d.owner, app);
    try app.flushEscape();
    _ = try app.feedInput("\x02yb");
    try expect(app.router.locked());
    _ = try app.feedInput("\x1b\x02");
    // Outside leader mode a reload applies at once, and a lock stays.
    try d.ok(&d.owner, "keys.register", replace);
    _ = try app.feedInput("\x02L");
    try c.sync(d);
    try answer(d, &d.owner, app);
    try expect(app.next_keymap == null and app.router.locked());
    // A reload still waiting when the client goes is freed: the allocator checks.
    _ = try app.feedInput("\x1b\x02\x02");
    try d.ok(&d.owner, "keys.register", replace);
    try c.sync(d);
    try answer(d, &d.owner, app);
    try expect(app.next_keymap != null);
}

test "on a non-Latin Kitty layout the leader, unlock and table keys work by base key, and other keys reach the pane unchanged" {
    const d = try Daemon.create();
    defer d.destroy();
    try d.ok(&d.owner, "keys.register", "{\"name\":\"plain\",\"prefix\":\"y\",\"bindings\":[{\"key\":\"é\",\"local\":\"zoom\"},{\"key\":\"e\",\"local\":\"lock\"}],\"bind\":\"daemon\"}");
    var c = try leaderClient(d, 120);
    defer c.deinit();
    const app = &c.app;
    const p0 = app.pane("p0").?;
    const greek = "\x1b[946::98;5u"; // ctrl+β on the B key
    const cyrillic = "\x1b[1080::98;5u"; // ctrl+и on the B key
    for ([_][]const u8{ greek, cyrillic }) |leader| {
        _ = try app.feedInput(leader);
        try expect(app.leaderPending());
        try expectInput(p0, "");
        // Leader leader sends the leader, and a table key goes by its base too.
        _ = try app.feedInput(leader);
        try expect(!app.leaderPending());
        try expectInput(p0, "\x02");
        _ = try app.feedInput(leader);
        _ = try app.feedInput("\x1b[955::108u"); // λ on the L key: focus-right
        try expectEqualStrings("p1", app.focus.?);
        _ = try app.feedInput("\x02\x1b[955::104u"); // back with η on the H key
        try expectEqualStrings("p0", app.focus.?);
    }
    // A shifted table key: Χ on the X key is `X`, close-pane.
    _ = try app.feedInput(greek);
    _ = try app.feedInput("\x1b[967:935:120;2u");
    try expectEqual(@as(usize, 1), app.requests.items.len);
    try expectEqualStrings("pane.kill", app.requests.items[0].verb);
    for (app.requests.items) |r| a.free(r.params);
    app.requests.clearRetainingCapacity();
    app.pending.clearRetainingCapacity();
    // Unlock, from either layout.
    for ([_][]const u8{ "\x1b[946::98;7u", "\x1b[1080::98;7u" }) |unlock| {
        _ = try app.feedInput("\x02L");
        try expect(app.router.locked());
        // While locked, the leader on that layout passes like any key.
        _ = try app.feedInput(greek);
        const want_locked = try reference("", greek);
        defer a.free(want_locked);
        try expectInput(p0, want_locked);
        _ = try app.feedInput(unlock);
        try expect(!app.router.locked());
        try expectInput(p0, "");
    }
    // Outside a chord, non-Latin letters reach the pane as they came: as text,
    // as a Kitty key on the B key, and with Ctrl on a key that is not the leader.
    for ([_][]const u8{ "βи", "\x1b[946::98u", "\x1b[945::97;5u" }) |bytes| {
        _ = try app.feedInput(bytes);
        try expect(!app.leaderPending());
        const want = try reference("", bytes);
        defer a.free(want);
        try expect(want.len > 0);
        try expectInput(p0, want);
    }
    // A key bound as the character itself wins over its base.
    _ = try app.feedInput("\x02y\x1b[233::101u");
    try expect(app.zoom != null and !app.router.locked());
    _ = try app.feedInput("\x02y\x1b[1077::101u"); // е on the E key has no binding of its own
    try expect(app.router.locked());
}

test "Kitty key repeat runs a sticky group's binding, and only that" {
    const d = try Daemon.create();
    defer d.destroy();
    var c = try leaderClient(d, 120);
    defer c.deinit();
    const app = &c.app;
    const p0 = app.pane("p0").?;
    for (0..30) |_| try p0.stream.vt.?.feed("line\r\n");
    const press = "\x1b[107;1:1u";
    const repeat = "\x1b[107;1:2u";
    const release = "\x1b[107;1:3u";
    _ = try app.feedInput("\x02[" ++ press);
    const first = p0.scroll.?;
    _ = try app.feedInput(repeat ++ repeat);
    try expectEqual(first - 2, p0.scroll.?);
    _ = try app.feedInput(release);
    try expect(app.leaderPending());
    // Holding the key that opened the group does not cancel it.
    _ = try app.feedInput("\x1b[91;1:2u");
    try expect(app.leaderPending());
    try expectEqual(first - 2, p0.scroll.?);
    try expectInput(p0, "");
    try app.flushEscape();
    try expect(!app.leaderPending());
    // Outside a sticky group a suppressed key's repeat is still dropped.
    _ = try app.feedInput("\x02");
    _ = try app.feedInput("\x1b[122;1:1u"); // z: zoom, then its repeat
    try expect(app.zoom != null);
    _ = try app.feedInput("\x1b[122;1:2u");
    try expectInput(p0, "");
    _ = try app.feedInput("\x1b[122;1:3u");
}

test "a bracketed paste ends leader mode, so the next typed key reaches the pane" {
    const d = try Daemon.create();
    defer d.destroy();
    var c = try leaderClient(d, 120);
    defer c.deinit();
    const app = &c.app;
    const p0 = app.pane("p0").?;
    tickAt(app, 1000);
    for ([_][]const u8{ "\x02", "\x02[" }) |keys_in| {
        _ = try app.feedInput(keys_in);
        tickAt(app, 2000);
        tickAt(app, 3000);
        try expect(app.popup.visible());
        _ = try app.feedInput("\x1b[200~text\x1b[201~");
        try expect(!app.leaderPending());
        tickAt(app, 3001);
        try expect(!app.popup.visible());
        try expectInput(p0, "text");
        _ = try app.feedInput("d");
        try expect(app.quit == null);
        try expectInput(p0, "d");
    }
    // A paste in lock mode keeps the lock.
    _ = try app.feedInput("\x02L\x1b[200~text\x1b[201~");
    try expect(app.router.locked());
    try expectInput(p0, "text");
}
fn surfaceText(surface: *const @import("venom-term").Surface) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(a);
    for (0..surface.height) |y| {
        for (0..surface.width) |x| try text.appendSlice(a, surface.get(@intCast(x), @intCast(y)).?.text);
        try text.append(a, '\n');
    }
    return text.toOwnedSlice(a);
}

test "an exec binding's child has no venomx token and placeholders are whole argv elements" {
    const d = try Daemon.create();
    defer d.destroy();
    try harness.topology(d);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(base);
    const out = try std.fs.path.join(a, &.{ base, "child.txt" });
    defer a.free(out);
    // Spliced placeholders are refused, never expanded.
    var vconn = d.connection(try d.principal(&.{ .{ .right = .write, .scope = "*" }, .{ .right = .read, .scope = "*" } }, "venom"));
    defer vconn.deinit();
    try expectCode(d, &vconn, "keys.register", "{\"name\":\"venom\",\"prefix\":\"a\",\"bindings\":[{\"key\":\"x\",\"exec\":[\"venom\",\"--pane={pane}\"]}]}", "invalid_params.bindings");
    const script = "env > \"$0\"; for x in \"$@\"; do printf '[%s]\\n' \"$x\"; done >> \"$0\"";
    const table = try std.fmt.allocPrint(a, "{{\"name\":\"venom\",\"prefix\":\"a\",\"bindings\":[{{\"key\":\"x\",\"exec\":[\"/bin/sh\",\"-c\",\"{s}\",\"{s}\",\"{{pane}}\",\"--session\",\"{{session}}\",\"{{window}}\",\"x {{pane}} y\"]}}]}}", .{ try escape(script), out });
    defer a.free(table);
    try expectCode(d, &vconn, "keys.register", "{\"name\":\"venom\",\"prefix\":\"a\",\"bindings\":[{\"key\":\"x\",\"exec\":[\"/bin/sh\",\"x {pane} y\"]}]}", "invalid_params.bindings");
    // Literal text without a placeholder token stays literal.
    const literal = try std.mem.replaceOwned(u8, a, table, "x {pane} y", "{pan}e");
    defer a.free(literal);
    try expectCode(d, &vconn, "keys.register", literal, "ok");
    var c = try Client.init(80, 24);
    defer c.deinit();
    try c.sync(d);
    try c.app.requestKeys();
    try answer(d, &d.owner, &c.app);
    try live(&c.app, "p0", "");
    try live(&c.app, "p1", "");
    _ = try c.app.feedInput("\x02\t\x02ax");
    try expectEqual(@as(usize, 1), c.app.execs.items.len);
    const argv = c.app.execs.items[0].argv;
    try expectEqualStrings("p1", argv[4]);
    try expectEqualStrings("s0", argv[6]);
    try expectEqualStrings("w0", argv[7]);
    try expectEqualStrings("{pan}e", argv[8]);
    // Run it as the client does, with a token, a principal and a
    // credential-looking value in the client environment.
    const env_in = [_:null]?[*:0]const u8{ "HOME=/nonexistent", "VENOMX_TOKEN=vnt1.venomx.g7.abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ", "VENOMX_PRINCIPAL=g7", "LEAK=see vnt1.venomx.g7.abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ", "VENOMX_PANE=p9", "PATH=/usr/bin:/bin", "NOTE=keep" };
    var env_arena = std.heap.ArenaAllocator.init(a);
    defer env_arena.deinit();
    const env = try exec.childEnviron(env_arena.allocator(), .{ .block = .{ .slice = &env_in } });
    const pid = try exec.spawn(a, argv, env);
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    try expectEqual(@as(c_int, 0), status);
    const text = try tmp.dir.readFileAlloc(std.testing.io, "child.txt", a, .limited(1 << 20));
    defer a.free(text);
    try expect(std.mem.indexOf(u8, text, "VENOMX_TOKEN") == null);
    try expect(std.mem.indexOf(u8, text, "VENOMX_PRINCIPAL") == null);
    try expect(std.mem.indexOf(u8, text, "LEAK=") == null);
    try expect(std.mem.indexOf(u8, text, "vnt1.") == null);
    try expect(std.mem.indexOf(u8, text, "NOTE=keep") != null);
    try expect(std.mem.indexOf(u8, text, "[p1]\n[--session]\n[s0]\n[w0]\n[{pan}e]\n") != null);
    // A failing exec is reported, not silent.
    var children: exec.Children = .{};
    defer children.deinit(a);
    try children.pids.append(a, try exec.spawn(a, &.{"/nonexistent/venom"}, env));
    var failed: ?exec.Children.Exit = null;
    for (0..2000) |_| {
        failed = children.reap();
        if (failed != null or children.pids.items.len == 0) break;
        std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake) catch {};
    }
    try expectEqual(@as(u8, 127), failed.?.status);
}
fn escape(text: []const u8) ![]const u8 {
    const State = struct {
        var buf: [512]u8 = undefined;
    };
    var w: std.Io.Writer = .fixed(&State.buf);
    for (text) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        else => try w.writeByte(ch),
    };
    return w.buffered();
}

test "pane.resize moves a split's shared divider, for every client, until the child's last cell" {
    const d = try Daemon.create();
    defer d.destroy();
    try harness.topology(d); // p0 | p1 in w0, each 80 wide until a client attaches.
    var wide = try Client.init(161, 25);
    defer wide.deinit();
    var narrow = try Client.init(81, 25);
    defer narrow.deinit();
    try wide.sync(d);
    try narrow.sync(d);
    try expectEqual(@as(u16, 80), wide.app.pane("p0").?.rect.width);
    try expectEqual(@as(u16, 40), narrow.app.pane("p0").?.rect.width);
    var r = try d.call(&d.owner, "window.get", "{\"window\":\"w0\"}");
    const first_revision = r.value.object.get("ok").?.object.get("revision").?.integer;
    try expect(r.value.object.get("ok").?.object.get("nodes").?.array.items[0].object.get("ratio") == null);
    r.deinit();
    // The divider follows the direction, from either side of it.
    var moved = try d.call(&d.owner, "pane.resize", "{\"pane\":\"p0\",\"direction\":\"right\",\"cells\":40}");
    try expectEqual(@as(i64, 40), moved.value.object.get("ok").?.object.get("moved").?.integer);
    try expectEqual(first_revision + 1, moved.value.object.get("ok").?.object.get("revision").?.integer);
    moved.deinit();
    try wide.sync(d);
    try narrow.sync(d);
    try expectEqual(@as(u16, 120), wide.app.pane("p0").?.rect.width);
    try expectEqual(@as(u16, 40), wide.app.pane("p1").?.rect.width);
    try expectEqual(@as(u16, 60), narrow.app.pane("p0").?.rect.width);
    try expectEqual(@as(u16, 20), narrow.app.pane("p1").?.rect.width);
    var from_right = try d.call(&d.owner, "pane.resize", "{\"pane\":\"p1\",\"direction\":\"left\",\"cells\":20}");
    try expectEqual(@as(i64, 20), from_right.value.object.get("ok").?.object.get("moved").?.integer);
    from_right.deinit();
    try wide.sync(d);
    try expectEqual(@as(u16, 100), wide.app.pane("p0").?.rect.width);
    // Stops at the last cell and says how far it went; then nothing moves.
    var far = try d.call(&d.owner, "pane.resize", "{\"pane\":\"p0\",\"direction\":\"right\",\"cells\":65535}");
    try expectEqual(@as(i64, 59), far.value.object.get("ok").?.object.get("moved").?.integer);
    far.deinit();
    try wide.sync(d);
    try expectEqual(@as(u16, 1), wide.app.pane("p1").?.rect.width);
    const events = d.events.entries.items.len;
    var stuck = try d.call(&d.owner, "pane.resize", "{\"pane\":\"p0\",\"direction\":\"right\",\"cells\":1}");
    try expectEqual(@as(i64, 0), stuck.value.object.get("ok").?.object.get("moved").?.integer);
    stuck.deinit();
    // No split on this axis: the same, and no event for either.
    var none = try d.call(&d.owner, "pane.resize", "{\"pane\":\"p0\",\"direction\":\"up\",\"cells\":1}");
    try expectEqual(@as(i64, 0), none.value.object.get("ok").?.object.get("moved").?.integer);
    none.deinit();
    try expectEqual(events, d.events.entries.items.len);
    // Split ratios are the window's: write on the pane alone is not enough.
    var reader = d.connection(try d.principal(&.{.{ .right = .read, .scope = "*" }}, "reader"));
    defer reader.deinit();
    try expectCode(d, &reader, "pane.resize", "{\"pane\":\"p0\",\"direction\":\"left\",\"cells\":1}", "denied.write");
    var self_only = d.connection(try d.principal(&.{ .{ .right = .read, .scope = "*" }, .{ .right = .write, .scope = "pane:p0" } }, "pane"));
    defer self_only.deinit();
    try expectCode(d, &self_only, "pane.resize", "{\"pane\":\"p0\",\"direction\":\"left\",\"cells\":1}", "denied.write");
    // Parameters and layers.
    try expectCode(d, &d.owner, "pane.resize", "{\"pane\":\"p0\",\"direction\":\"sideways\",\"cells\":1}", "invalid_params.enum");
    try expectCode(d, &d.owner, "pane.resize", "{\"pane\":\"p0\",\"direction\":\"up\",\"cells\":0}", "invalid_params.range");
    try expectCode(d, &d.owner, "pane.resize", "{\"pane\":\"p99\",\"direction\":\"up\",\"cells\":1}", "not_found.pane");
    try d.ok(&d.owner, "pane.float", "{\"window\":\"w0\",\"argv\":[\"true\"]}");
    const floating = d.product.panes.items[d.product.panes.items.len - 1].id;
    const params = try std.fmt.allocPrint(a, "{{\"pane\":\"{s}\",\"direction\":\"up\",\"cells\":1}}", .{floating});
    defer a.free(params);
    try expectCode(d, &d.owner, "pane.resize", params, "conflict.layer");
}

test "splitting a pane at the minimum clamps the ratio, and pane.resize never moves against the direction" {
    const d = try Daemon.create();
    defer d.destroy();
    try harness.topology(d);
    var c = try Client.init(161, 25);
    defer c.deinit();
    try c.sync(d);
    try d.ok(&d.owner, "pane.resize", "{\"pane\":\"p0\",\"direction\":\"left\",\"cells\":65535}");
    try c.sync(d);
    try expectEqual(@as(u16, 1), c.app.pane("p0").?.rect.width);
    const wide = c.app.pane("p1").?.rect.width;
    try d.ok(&d.owner, "pane.split", "{\"pane\":\"p0\",\"axis\":\"cols\",\"argv\":[\"true\"]}");
    try c.sync(d);
    // Clamped: the two panes get a column each, all of it from p1.
    try expect(c.app.pane("p0").?.rect.width > 0);
    var w = try d.call(&d.owner, "window.get", "{\"window\":\"w0\"}");
    const nodes = w.value.object.get("ok").?.object.get("nodes").?.array.items;
    const new = nodes[1].object.get("second").?.integer;
    const new_id = nodes[@intCast(new)].object.get("pane").?.string;
    try expect(c.app.pane(new_id).?.rect.width > 0);
    const clamped = nodes[0].object.get("ratio").?.integer;
    try expect(clamped < 5000);
    try expect(c.app.pane("p1").?.rect.width >= wide - 2);
    w.deinit();
    const before = c.app.pane("p1").?.rect.width;
    var right = try d.call(&d.owner, "pane.resize", "{\"pane\":\"p1\",\"direction\":\"right\",\"cells\":1}");
    try expectEqual(@as(i64, 1), right.value.object.get("ok").?.object.get("moved").?.integer);
    right.deinit();
    try c.sync(d);
    // Moved right: this harness's PTYs are wider than the client, so it rounds.
    try expect(c.app.pane("p1").?.rect.width <= before);
    var after = try d.call(&d.owner, "window.get", "{\"window\":\"w0\"}");
    defer after.deinit();
    try expect(after.value.object.get("ok").?.object.get("nodes").?.array.items[0].object.get("ratio").?.integer > clamped);
}

test "leader r is a sticky resize group of h j k l and the arrows, sent as pane.resize, until esc" {
    const d = try Daemon.create();
    defer d.destroy();
    var c = try leaderClient(d, 161);
    defer c.deinit();
    const app = &c.app;
    const width = struct {
        fn f(x: *Client, id: []const u8) u16 {
            return x.app.pane(id).?.rect.width;
        }
    }.f;
    var other = try Client.init(161, 24);
    defer other.deinit();
    try other.sync(d);
    const step = struct {
        fn f(dm: *Daemon, x: *Client, y: *Client, key: []const u8) !void {
            _ = try x.app.feedInput(key);
            try answer(dm, &dm.owner, &x.app);
            try x.sync(dm);
            try y.sync(dm);
        }
    }.f;
    try expectEqual(@as(u16, 80), width(&c, "p0"));
    // The first key: the group opens and stays; the popup is there on a delay.
    tickAt(app, 1000);
    _ = try app.feedInput("\x02r");
    tickAt(app, 1000);
    try expect(app.router.stickyGroup() != null);
    tickAt(app, 1200);
    try expect(app.popup.visible());
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const model = try app.popupModel(arena.allocator());
    try expectEqualStrings("venomx › resize", model.title);
    try expect(popupRow(model, "l →") != null);
    // Each key runs and stays; the popup goes down after the first. Both clients follow.
    for ([_]struct { key: []const u8, want: u16 }{
        .{ .key = "l", .want = 81 },
        .{ .key = "l", .want = 82 },
        .{ .key = "\x1b[C", .want = 83 },
        .{ .key = "h", .want = 82 },
        .{ .key = "\x1b[D", .want = 81 },
    }) |t| {
        try step(d, &c, &other, t.key);
        try expectEqual(t.want, width(&c, "p0"));
        try expectEqual(t.want, width(&other, "p0"));
        tickAt(app, 2000);
        try expect(app.router.stickyGroup() != null and app.leaderPending());
        try expect(!app.popup.visible());
    }
    // Up and down have no rows split here: they move nothing and report nothing.
    const moves_before = d.events.entries.items.len;
    for ([_][]const u8{ "j", "k", "\x1b[A", "\x1b[B" }) |key| {
        try expect(app.router.stickyGroup() != null);
        try step(d, &c, &other, key);
    }
    try expectEqual(moves_before, d.events.entries.items.len);
    try expectEqual(@as(usize, 0), app.message.items.len);
    // Holding a key repeats it, inside the group.
    try step(d, &c, &other, "\x1b[108;1:1u\x1b[108;1:2u\x1b[108;1:2u\x1b[108;1:3u");
    try expectEqual(@as(u16, 84), width(&c, "p0"));
    try step(d, &c, &other, "\x1b[104;1:1u\x1b[104;1:2u\x1b[104;1:2u\x1b[104;1:3u");
    try expectEqual(@as(u16, 81), width(&c, "p0"));
    // esc ends it, and keys reach the pane again.
    _ = try app.feedInput("\x1b");
    try app.flushEscape();
    try expect(!app.leaderPending());
    _ = try app.feedInput("l");
    try expectEqual(@as(usize, 0), app.requests.items.len);
    try expectEqual(@as(u16, 81), width(&c, "p0"));
    // A rows split answers to j and k, on the focused pane's split.
    try d.ok(&d.owner, "pane.split", "{\"pane\":\"p0\",\"axis\":\"rows\",\"argv\":[\"true\"]}");
    try c.sync(d);
    // The new pane is live at the daemon's size, as an attached client has it
    // (the title row makes this window's rows odd, which exposes the rounding
    // of a pane the client still sizes by its own viewport).
    try liveAtDaemonSize(d, app);
    const before = app.pane("p0").?.rect.height;
    _ = try app.feedInput("\x02r");
    try step(d, &c, &other, "j");
    try expectEqual(before + 1, app.pane("p0").?.rect.height);
    try step(d, &c, &other, "\x1b[A");
    try expectEqual(before, app.pane("p0").?.rect.height);
    // The names work at the prompt too.
    try expect(keys.parseCommand("resize-left").? == .verb);
    try expectEqualStrings("pane.resize", keys.parseCommand("resize-up").?.verb.wire());
}

/// Give each of the client's panes a live stream and a Vt of the PTY size the
/// daemon has for it, as a client that is attached and settled has.
fn liveAtDaemonSize(d: *Daemon, app: *App) !void {
    for (app.panes.items) |p| {
        const size = d.product.pane(p.stream.pane).?.pane.vt.size();
        if (p.stream.vt == null) p.stream.vt = try Vt.init(a, .{ .cols = size.cols, .rows = size.rows });
        p.stream.pane_size = .{ .cols = size.cols, .rows = size.rows };
        p.stream.phase = .live;
        p.stream.writer = true;
    }
}

test "queued resize presses each move the divider on the pressing client, on both axes, in both directions" {
    const d = try Daemon.create();
    defer d.destroy();
    try harness.topology(d); // w0 = p0 | p1
    try d.ok(&d.owner, "pane.split", "{\"pane\":\"p0\",\"axis\":\"rows\",\"argv\":[\"true\"]}");
    // The tall client has twice the narrow one's cells each way, so a PTY cell
    // is half a cell for it on both axes.
    var wide = try Client.init(161, 49);
    defer wide.deinit();
    var narrow = try Client.init(81, 25);
    defer narrow.deinit();
    const Probe = struct {
        fn extent(c: *Client, axis: layout_axis) u16 {
            const r = c.app.pane("p0").?.rect;
            return if (axis == .cols) r.width else r.height;
        }
    };
    for ([_]*Client{ &wide, &narrow }) |c| {
        try c.sync(d);
        try c.app.requestKeys();
        try answer(d, &d.owner, &c.app);
        try liveAtDaemonSize(d, &c.app);
        try expectEqualStrings("p0", c.app.focus.?);
    }
    // Presses before any answer: the tree each client holds does not change.
    const cases = [_]struct { axis: layout_axis, plus: []const u8, minus: []const u8 }{
        .{ .axis = .cols, .plus = "l", .minus = "h" },
        .{ .axis = .rows, .plus = "j", .minus = "k" },
    };
    for ([_]*Client{ &wide, &narrow }) |c| {
        _ = try c.app.feedInput("\x02r");
        for (cases) |case| for ([_]struct { key: []const u8, sign: i32 }{ .{ .key = case.plus, .sign = 1 }, .{ .key = case.minus, .sign = -1 } }) |dir| {
            const other: *Client = if (c == &wide) &narrow else &wide;
            const start: i32 = Probe.extent(c, case.axis);
            for (1..6) |n| {
                _ = try c.app.feedInput(dir.key);
                // Nothing is answered yet, so each press is one more request.
                try expectEqual(n, c.app.requests.items.len);
            }
            // Each answer moves the divider by at least one cell of this client.
            var at = start;
            for (0..5) |_| {
                try answerFirst(d, &d.owner, &c.app);
                try c.sync(d);
                try other.sync(d);
                const now: i32 = Probe.extent(c, case.axis);
                try expect((now - at) * dir.sign >= 1);
                at = now;
            }
            try expectEqual(start + dir.sign * 5, at);
            try expectEqual(@as(usize, 0), c.app.presses.items.len);
        };
    }
}

test "a refused press among queued ones leaves the next presses moving, with no double count" {
    const d = try Daemon.create();
    defer d.destroy();
    try harness.topology(d);
    var c = try Client.init(81, 25);
    defer c.deinit();
    try c.sync(d);
    try c.app.requestKeys();
    try answer(d, &d.owner, &c.app);
    try liveAtDaemonSize(d, &c.app);
    _ = try c.app.feedInput("\x02r");
    // Two presses go out on a tree that is stale: another client has already
    // pushed the divider to its limit, so the daemon refuses both.
    _ = try c.app.feedInput("l");
    _ = try c.app.feedInput("l");
    try d.ok(&d.owner, "pane.resize", "{\"pane\":\"p0\",\"direction\":\"right\",\"cells\":65535}");
    try answer(d, &d.owner, &c.app);
    try expectEqual(@as(usize, 0), c.app.presses.items.len);
    try c.sync(d);
    try expectEqual(@as(u16, 1), c.app.pane("p1").?.rect.width);
    // Left presses now queue; the refused ones must not shift them.
    for (0..3) |_| _ = try c.app.feedInput("h");
    var at: i32 = c.app.pane("p0").?.rect.width;
    for (0..3) |_| {
        try answerFirst(d, &d.owner, &c.app);
        try c.sync(d);
        const now: i32 = c.app.pane("p0").?.rect.width;
        try expect(at - now >= 1);
        at = now;
    }
    try expectEqual(@as(usize, 0), c.app.presses.items.len);
}

test "another client's layout change between presses neither drops a queued press nor counts it twice" {
    const d = try Daemon.create();
    defer d.destroy();
    try resizeTopology(d);
    var c = try Client.init(81, 25);
    defer c.deinit();
    try c.sync(d);
    try c.app.requestKeys();
    try answer(d, &d.owner, &c.app);
    try liveAtDaemonSize(d, &c.app);
    _ = try c.app.feedInput("\x02r");
    _ = try c.app.feedInput("l");
    _ = try c.app.feedInput("l");
    // A foreign resize lands, and this client sees its event before its own answers.
    try d.ok(&d.owner, "pane.resize", "{\"pane\":\"p0\",\"direction\":\"left\",\"cells\":10}");
    try c.sync(d);
    try expectEqual(@as(usize, 2), c.app.presses.items.len);
    _ = try c.app.feedInput("l");
    var at: i32 = c.app.pane("p0").?.rect.width;
    for (0..3) |_| {
        try answerFirst(d, &d.owner, &c.app);
        try c.sync(d);
        const now: i32 = c.app.pane("p0").?.rect.width;
        try expect(now - at >= 1);
        at = now;
    }
    try expectEqual(@as(usize, 0), c.app.presses.items.len);
    // 40 columns initially, minus 5 from the foreign 10-PTY-cell move,
    // plus exactly one viewport column for each of our three presses.
    try expectEqual(@as(i32, 38), at);
}

test "legacy control bytes reach the pane unchanged, and the router still reads them" {
    const d = try Daemon.create();
    defer d.destroy();
    try harness.topology(d);
    var c = try Client.init(80, 24);
    defer c.deinit();
    try c.sync(d);
    try c.app.requestKeys();
    try answer(d, &d.owner, &c.app);
    const kitty = "\x1b[>1u";
    try live(&c.app, "p0", "");
    try live(&c.app, "p1", kitty);
    const p0 = c.app.pane("p0").?;
    const p1 = c.app.pane("p1").?;
    try expectEqualStrings("p0", c.app.focus.?);
    const cases = [_]struct { host: []const u8, name: []const u8, csi_u: []const u8 }{
        .{ .host = "\x1c", .name = "ctrl+\\", .csi_u = "\x1b[92;5u" },
        .{ .host = "\x1d", .name = "ctrl+]", .csi_u = "\x1b[93;5u" },
        .{ .host = "\x1e", .name = "ctrl+^", .csi_u = "\x1b[94;5u" },
        .{ .host = "\x1f", .name = "ctrl+_", .csi_u = "\x1b[95;5u" },
        .{ .host = "\x1b\x00", .name = "ctrl+alt+space", .csi_u = "\x1b[32;7u" },
    };
    // A legacy pane gets the host's bytes, from a legacy or a Kitty host.
    for (cases) |case| {
        _ = try c.app.feedInput(case.host);
        try expectInput(p0, case.host);
        _ = try c.app.feedInput(case.csi_u);
        try expectInput(p0, case.host);
        try expectInput(p1, "");
    }
    // ESC and any other control byte too: only the leader stops here.
    var byte: u8 = 0x01;
    while (byte < 0x20) : (byte += 1) {
        const sent = [_]u8{ 0x1b, byte };
        _ = try c.app.feedInput(&sent);
        try expectInput(p0, &sent);
    }
    // A Kitty pane gets the key as Kitty names it.
    _ = try c.app.feedInput("\x02\t");
    try expectEqualStrings("p1", c.app.focus.?);
    for (cases) |case| {
        _ = try c.app.feedInput(case.host);
        try expectInput(p1, case.csi_u);
    }
    _ = try c.app.feedInput("\x02\t");
    try expectEqualStrings("p0", c.app.focus.?);
    // Each is the same chord to the router: as the leader it is intercepted,
    // and leader leader sends the pane the same bytes.
    const leader = c.app.keymap.settings.leader;
    defer c.app.keymap.settings.leader = leader;
    for (cases) |case| {
        c.app.keymap.settings.leader = keys.parseChord(case.name).?;
        _ = try c.app.feedInput(case.host);
        try expect(c.app.leaderPending());
        try expectInput(p0, "");
        _ = try c.app.feedInput(case.host);
        try expect(!c.app.leaderPending());
        try expectInput(p0, case.host);
        _ = try c.app.feedInput(case.csi_u);
        try expect(c.app.leaderPending());
        _ = try c.app.feedInput(case.csi_u);
        try expect(!c.app.leaderPending());
        try expectInput(p0, case.host);
    }
}

/// Resize needs authoritative trees and pane sizes, but no child processes.
/// Seed two split windows in the existing daemon harness with in-memory panes;
/// subsequent replies and events still come from the real Product/dispatcher.
fn resizeTopology(d: *Daemon) !void {
    const product = @import("product.zig");
    const Node = @import("layout.zig").Node;
    try d.ok(&d.owner, "session.create", "{\"name\":\"work\"}");
    for (0..2) |i| {
        const w = try a.create(product.Window);
        w.* = .{
            .id = try std.fmt.allocPrint(a, "w{d}", .{i}),
            .name = try a.dupe(u8, "resize"),
            .session = d.product.sessions.items[0],
            .owner = g.owner,
            .nodes = try a.alloc(Node, 3),
        };
        try d.product.windows.append(a, w);
        w.nodes[0] = .{ .kind = .split, .axis = .cols, .first = 1, .second = 2 };
        for (1..3) |j| {
            const pane = try d.server.createPane(.{ .cols = 80, .rows = 24 });
            const p = try a.create(product.Pane);
            p.* = .{
                .id = try a.dupe(u8, pane.id),
                .window = w,
                .owner = g.owner,
                .principal = g.owner,
                .pane = pane,
                .observation = @import("observation.zig").Observation.init(a, &d.events, pane.id),
                .exit_published = true,
            };
            // Exited panes permit window.remove to finish in the same turn.
            pane.status = .{ .code = 0 };
            try d.product.panes.append(a, p);
            w.nodes[j] = .{ .kind = .pane, .pane = p.id };
        }
        const resource = try std.fmt.allocPrint(a, "window:{s}", .{w.id});
        defer a.free(resource);
        try d.events.append(resource, "window.created", .{ .window = w.id, .session = w.session.id, .name = w.name, .revision = w.revision, .nodes = w.nodes });
    }
    d.product.next_window = 2;
}

// Keep setup outside the failure-injected operation: only the resize press
// allocates through the supplied allocator.
fn resizePressAllocationFailures(allocator: std.mem.Allocator, failed_request: *bool) !void {
    const d = try Daemon.create();
    defer d.destroy();
    try resizeTopology(d);
    var c = try Client.init(81, 25);
    defer c.deinit();
    try c.sync(d);
    try liveAtDaemonSize(d, &c.app);
    c.app.a = allocator;
    defer {
        // These queues start empty; account for all injected allocations before
        // restoring the allocator that owns the fixture's topology and streams.
        c.app.clearPresses();
        c.app.presses.deinit(allocator);
        c.app.presses = .empty;
        for (c.app.requests.items) |r| allocator.free(r.params);
        c.app.requests.deinit(allocator);
        c.app.requests = .empty;
        c.app.pending.deinit(allocator);
        c.app.pending = .empty;
        c.app.a = a;
    }
    c.app.run(.{ .verb = .resize_right }) catch |err| {
        // A retained capacity means pressCells appended successfully, so this
        // failure came from request and must have rolled back that press.
        if (c.app.presses.capacity > 0) failed_request.* = true;
        try expectEqual(@as(usize, 0), c.app.presses.items.len);
        try expectEqual(@as(usize, 0), c.app.requests.items.len);
        try expectEqual(@as(usize, 0), c.app.pending.items.len);
        return err;
    };
    try expectEqual(@as(usize, 1), c.app.presses.items.len);
    try expectEqual(@as(usize, 1), c.app.requests.items.len);
}

test "a failed resize request leaves no queued press at every allocation failure" {
    var failed_request = false;
    try std.testing.checkAllAllocationFailures(a, resizePressAllocationFailures, .{&failed_request});
    try expect(failed_request);
}

test "an error reply drops only its queued resize press before any layout event" {
    const d = try Daemon.create();
    defer d.destroy();
    try resizeTopology(d);
    var c = try Client.init(81, 25);
    defer c.deinit();
    try c.sync(d);
    try liveAtDaemonSize(d, &c.app);
    try c.app.run(.{ .verb = .resize_right });
    try c.app.run(.{ .verb = .resize_right });
    const remaining = c.app.presses.items[1].id;
    var reader = d.connection(try d.principal(&.{.{ .right = .read, .scope = "*" }}, "reader"));
    defer reader.deinit();
    try answerFirst(d, &reader, &c.app);
    try expect(std.mem.indexOf(u8, reader.output.items, "denied.write") != null);
    try expectEqual(@as(usize, 1), c.app.presses.items.len);
    try expectEqual(remaining, c.app.presses.items[0].id);
    try expectEqual(@as(u16, 40), c.app.pane("p0").?.rect.width);
    try answerFirst(d, &d.owner, &c.app);
    try c.sync(d);
    try expectEqual(@as(usize, 0), c.app.presses.items.len);
    try expectEqual(@as(u16, 41), c.app.pane("p0").?.rect.width);
}

test "window.removed prunes unanswered presses without waiting for their replies" {
    const d = try Daemon.create();
    defer d.destroy();
    try resizeTopology(d);
    var c = try Client.init(81, 25);
    defer c.deinit();
    try c.sync(d);
    try liveAtDaemonSize(d, &c.app);
    try c.app.run(.{ .verb = .resize_right });
    try c.app.run(.{ .verb = .resize_right });
    try expectEqual(@as(usize, 2), c.app.presses.items.len);
    // Deliver the actual daemon event stream, leaving both requests unanswered.
    try d.ok(&d.owner, "window.remove", "{\"window\":\"w0\",\"recursive\":true}");
    try c.sync(d);
    try expectEqual(@as(usize, 0), c.app.presses.items.len);
    try expectEqual(@as(usize, 2), c.app.requests.items.len);
    try expectEqualStrings("w1", c.app.active.?);
}

test "presses in a second window do not enter the active window overlay" {
    const d = try Daemon.create();
    defer d.destroy();
    try resizeTopology(d);
    var c = try Client.init(81, 25);
    defer c.deinit();
    try c.sync(d);
    try liveAtDaemonSize(d, &c.app);
    try c.app.run(.{ .verb = .resize_right });
    try c.app.run(.{ .local = .window_next });
    try liveAtDaemonSize(d, &c.app);
    try expectEqualStrings("w1", c.app.active.?);
    const start = c.app.pane("p2").?.rect.width;
    for (0..3) |_| try c.app.run(.{ .verb = .resize_right });
    try expectEqual(@as(usize, 4), c.app.presses.items.len);
    try expectEqualStrings("w0", c.app.presses.items[0].window);
    for (c.app.presses.items[1..]) |press| try expectEqualStrings("w1", press.window);
    // Answer w0 while w1 is active; its reply must not drop w1's presses.
    try answerFirst(d, &d.owner, &c.app);
    try c.sync(d);
    try expectEqual(start, c.app.pane("p2").?.rect.width);
    try expectEqual(@as(usize, 3), c.app.presses.items.len);
    for (1..4) |n| {
        try answerFirst(d, &d.owner, &c.app);
        try c.sync(d);
        try expectEqual(start + @as(u16, @intCast(n)), c.app.pane("p2").?.rect.width);
    }
    try expectEqual(@as(usize, 0), c.app.presses.items.len);
}

test "real reconnect forgets unanswered resize presses" {
    const d = try Daemon.create();
    defer d.destroy();
    try resizeTopology(d);
    var c = try Client.init(81, 25);
    defer c.deinit();
    try c.sync(d);
    try liveAtDaemonSize(d, &c.app);
    try c.app.run(.{ .verb = .resize_right });
    try expectEqual(@as(usize, 1), c.app.presses.items.len);
    try expect(try @import("attach.zig").TestReconnect.run(&c.app));
    try expectEqual(@as(usize, 0), c.app.presses.items.len);
    try expect(!c.app.topology_ready);
    try expectEqualStrings("reconnected", c.app.message.items);
}

test "} from the loading band lands on a prompt at the oldest loaded row" {
    const d = try Daemon.create();
    defer d.destroy();
    var c = try leaderClient(d, 120);
    defer c.deinit();
    const p0 = c.app.pane("p0").?;
    if (p0.stream.vt) |*old| old.deinit();
    p0.stream.vt = try Vt.init(a, .{ .cols = 500, .rows = 6, .scrollback_lines = 50 });
    const vt = p0.stream.vt.?;
    // Every row a prompt start, and enough of them to trim history.
    for (0..400) |_| try vt.feed("\x1b]133;A\x07$ \r\n");
    const rows = vt.rows();
    try expect(rows.oldest > 4);
    try expectEqual(Vt.RowPrompt.start, try vt.rowPrompt(rows.epoch, rows.oldest));
    // Rows below `oldest` are still arriving as SCROLLBACK.
    p0.stream.backfill = .pending;
    p0.stream.history_epoch = rows.epoch;
    p0.stream.history_floor = rows.oldest - 4;
    p0.scroll = rows.oldest - 2;
    p0.scroll_epoch = rows.epoch;
    _ = try c.app.feedInput("\x02[}");
    try expectEqual(rows.oldest, p0.scroll.?);
}
