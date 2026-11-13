//! Shared chrome conformance cases (per-client views, segments, namespaces,
//! attention), plus the daemon rules for tags, segments, attention and
//! notifications. A real `Product` and dispatcher run in process; every presentation
//! client is an `attach` App fed the daemon's own event log, so the data
//! path is the one a real client sees.
const std = @import("std");
const proto = @import("proto");
const term = @import("venom-term");
const g = proto.grants;
const streams = @import("server.zig");
const supervisor = @import("supervisor");
const manifest = @import("manifest.zig");
const product_mod = @import("product.zig");
const Product = product_mod.Product;
const chrome = @import("chrome.zig");
const App = @import("attach_app.zig").App;
const windowLabel = @import("attach_app.zig").windowLabel;
const a = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const Value = std.json.Value;

pub const Daemon = struct {
    events: proto.events.Log,
    registry: g.Registry,
    server: streams.Server,
    leaders: supervisor.Leaders,
    product: Product,
    bindings: [@import("manifest.zig").product.len + 1]proto.Binding,
    dispatcher: proto.Dispatcher,
    owner: proto.Connection,
    next_id: i64 = 0,
    pub fn create() !*Daemon {
        const d = try a.create(Daemon);
        errdefer a.destroy(d);
        d.events = try proto.events.Log.init(a, "venomx", .{}, null);
        d.events.catalog = &manifest.catalog;
        d.registry = try g.Registry.init(a, "venomx", .{});
        d.server = streams.Server.init(a, d.events.source);
        d.leaders = supervisor.Leaders.init(a, .{});
        d.product = .{ .a = a, .streams = &d.server, .registry = &d.registry, .events = &d.events, .environ = .empty, .leaders = &d.leaders };
        d.registry.containment = g.Containment.init(&d.product);
        d.server.on_closed = .{ .context = &d.product, .f = Product.connectionClosed };
        d.bindings = d.product.bindings() ++ .{proto.Binding{ .verb = "events", .handler = proto.VerbHandler.init(&d.events) }};
        d.dispatcher = try proto.Dispatcher.init(a, &manifest.core_model, &d.bindings, .{}, null);
        d.owner = d.connection(g.owner);
        d.next_id = 0;
        return d;
    }
    pub fn destroy(d: *Daemon) void {
        d.owner.deinit();
        d.dispatcher.deinit();
        d.product.deinit();
        d.leaders.deinit();
        d.server.deinit();
        d.registry.deinit();
        d.events.deinit();
        a.destroy(d);
    }
    pub fn connection(d: *Daemon, who: g.Id) proto.Connection {
        var conn = proto.Connection.init(a, -1);
        conn.protocol = .ndjson;
        conn.ready = true;
        conn.version = 1;
        conn.registry = &d.registry;
        conn.identity = .{ .principal = who };
        return conn;
    }
    /// A token principal issued by the owner with these grants and namespace.
    pub fn principal(d: *Daemon, grants: []const g.Grant, namespace: ?[]const u8) !g.Id {
        const issued = try d.registry.issueChild(.{ .principal = g.owner }, .{ .kind = .token, .grants = grants, .namespace = namespace }, g.nowSeconds());
        a.free(issued.token);
        return issued.principal;
    }
    /// One request; returns the parsed response line (caller deinits).
    pub fn call(d: *Daemon, conn: *proto.Connection, verb: []const u8, params: []const u8) !std.json.Parsed(Value) {
        conn.output.clearRetainingCapacity();
        conn.sent = 0;
        d.next_id += 1;
        const line = try std.fmt.allocPrint(a, "{{\"id\":{d},\"verb\":\"{s}\",\"params\":{s}}}", .{ d.next_id, verb, params });
        defer a.free(line);
        try d.dispatcher.message(conn, .{ .ndjson = line });
        const out = std.mem.trimEnd(u8, conn.output.items, "\n");
        return std.json.parseFromSlice(Value, a, out, .{});
    }
    pub fn ok(d: *Daemon, conn: *proto.Connection, verb: []const u8, params: []const u8) !void {
        var r = try d.call(conn, verb, params);
        defer r.deinit();
        if (r.value.object.get("ok") == null) {
            std.debug.print("{s} failed: {s}\n", .{ verb, conn.output.items });
            return error.CallFailed;
        }
    }
    pub fn code(d: *Daemon, conn: *proto.Connection, verb: []const u8, params: []const u8) ![]const u8 {
        var r = try d.call(conn, verb, params);
        defer r.deinit();
        const e = r.value.object.get("error") orelse return "ok";
        const c = e.object.get("code").?.string;
        inline for (.{ "denied.namespace", "denied.write", "invalid_params.segment", "invalid_params.tags", "conflict.segment_limit", "not_found.segment", "not_found.notification", "invalid_params.attention" }) |known| if (std.mem.eql(u8, c, known)) return known;
        std.debug.print("unexpected {s}\n", .{c});
        return "other";
    }
};

/// A presentation client of session s0 that has seen the daemon's log up
/// to `seen`.
pub const Client = struct {
    app: App,
    seen: usize = 0,
    pub fn init(cols: u16, rows: u16) !Client {
        var app = try App.init(a, .{ .session = "s0" }, .{ .cols = cols, .rows = rows }, .{});
        app.fixed_clock = "14:02";
        app.fixed_now = 1000;
        try app.control("{\"id\":2,\"item\":{\"type\":\"state.snapshot\",\"data\":{\"entities\":[]}}}");
        try app.control("{\"id\":2,\"item\":{\"type\":\"stream.checkpoint\",\"data\":{}}}");
        return .{ .app = app };
    }
    pub fn deinit(self: *Client) void {
        self.app.deinit();
    }
    /// Deliver every retained event the client has not seen.
    pub fn sync(self: *Client, d: *Daemon) !void {
        const entries = d.events.entries.items[d.events.head..];
        for (entries[@min(self.seen, entries.len)..]) |e| {
            const line = try std.fmt.allocPrint(a, "{{\"id\":2,\"item\":{s}}}", .{e.bytes});
            defer a.free(line);
            try self.app.control(line);
        }
        self.seen = entries.len;
    }
    /// Send the client's queued verb requests under `conn`'s identity.
    pub fn flush(self: *Client, d: *Daemon, conn: *proto.Connection) !void {
        for (self.app.requests.items) |r| {
            defer a.free(r.params);
            if (std.mem.eql(u8, r.verb, "config.get")) continue;
            try d.ok(conn, r.verb, r.params);
        }
        self.app.requests.clearRetainingCapacity();
    }
    pub fn screen(self: *Client) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(a);
        defer out.deinit();
        var surface = try term.Surface.init(a, self.app.cols, self.app.rows);
        defer surface.deinit(&out.writer);
        try self.app.render(&surface);
        var text: std.ArrayList(u8) = .empty;
        errdefer text.deinit(a);
        for (0..self.app.rows) |y| {
            for (0..self.app.cols) |x| try text.appendSlice(a, surface.get(@intCast(x), @intCast(y)).?.text);
            try text.append(a, '\n');
        }
        return text.toOwnedSlice(a);
    }
    /// The status line (the top row by default).
    pub fn status(self: *Client) ![]u8 {
        const all = try self.screen();
        defer a.free(all);
        const y = self.app.statusRow() orelse return a.dupe(u8, "");
        var rows = std.mem.splitScalar(u8, all, '\n');
        for (0..y) |_| _ = rows.next();
        return a.dupe(u8, rows.next() orelse "");
    }
};

/// s0 with w0 = [p0 | p1] and w1 = [p2], all created by the owner.
pub fn topology(d: *Daemon) !void {
    try d.ok(&d.owner, "session.create", "{\"name\":\"work\"}");
    try d.ok(&d.owner, "window.create", "{\"session\":\"s0\",\"argv\":[\"true\"],\"tags\":[{\"key\":\"role\",\"value\":\"agent\"}]}");
    try d.ok(&d.owner, "pane.split", "{\"pane\":\"p0\",\"axis\":\"cols\",\"argv\":[\"true\"],\"tags\":[{\"key\":\"role\",\"value\":\"agent\"},{\"key\":\"group\",\"value\":\"thread-7\"}]}");
    try d.ok(&d.owner, "window.create", "{\"session\":\"s0\",\"argv\":[\"true\"]}");
}

test "two clients keep their own window, focus, scroll and zoom; no verb changes another client's view" {
    const d = try Daemon.create();
    defer d.destroy();
    try topology(d);
    var one = try Client.init(80, 24);
    defer one.deinit();
    var two = try Client.init(80, 24);
    defer two.deinit();
    try one.sync(d);
    try two.sync(d);
    try expectEqualStrings("w0", one.app.active.?);
    // Window and focus are per client.
    try two.app.run(.{ .local = .window_next });
    try one.app.run(.{ .local = .focus_next });
    try expectEqualStrings("w1", two.app.active.?);
    try expectEqualStrings("w0", one.app.active.?);
    try expectEqualStrings("p1", one.app.focus.?);
    try expectEqualStrings("p2", two.app.focus.?);
    // Zoom is a local action: no request, and no new viewport (so no PTY
    // resize for anyone).
    const p1 = one.app.pane("p1").?;
    const frames = p1.stream.outbox.items.len;
    const tiled = p1.rect;
    try one.app.run(.{ .local = .zoom });
    try expect(one.app.zoomed() == p1);
    try expectEqual(frames, p1.stream.outbox.items.len);
    try expectEqual(@as(u16, 80), p1.rect.width);
    try expect(tiled.width < 80);
    try expectEqual(@as(u16, 0), one.app.pane("p0").?.rect.width);
    const zoomed = try one.status();
    defer a.free(zoomed);
    try expect(std.mem.indexOf(u8, zoomed, " true   true  │ [Z]") != null);
    try expect(two.app.zoom == null);
    // Scroll is per client too (covered against real streams by "two
    // clients scroll and select independently"): no local action queued
    // anything for the daemon.
    try one.app.run(.{ .local = .scroll_page_up });
    try expectEqual(@as(usize, 0), one.app.requests.items.len - countVerb(&one.app, "config.get"));
    try expectEqual(@as(usize, 0), two.app.requests.items.len - countVerb(&two.app, "config.get"));
    // Every shared-state verb leaves both views alone.
    const product = try d.principal(&.{ .{ .right = .write, .scope = "*" }, .{ .right = .read, .scope = "*" } }, "venom");
    var conn = d.connection(product);
    defer conn.deinit();
    try d.ok(&conn, "pane.attention", "{\"pane\":\"p2\",\"level\":\"urgent\",\"reason\":\"approve\"}");
    try d.ok(&conn, "pane.tag", "{\"pane\":\"p1\",\"set\":[{\"key\":\"x\",\"value\":\"y\"}]}");
    try d.ok(&conn, "status.set", "{\"id\":\"venom.agents\",\"text\":\"2 running\"}");
    try d.ok(&conn, "notify.post", "{\"text\":\"look at p2\",\"pane\":\"p2\"}");
    try one.sync(d);
    try two.sync(d);
    try expectEqualStrings("w0", one.app.active.?);
    try expectEqualStrings("p1", one.app.focus.?);
    try expect(one.app.zoomed() == p1);
    try expectEqualStrings("w1", two.app.active.?);
    try expectEqualStrings("p2", two.app.focus.?);
    // The schema has no verb, and no parameter, that targets a client's view.
    for (manifest.model.verbs) |v| {
        for ([_][]const u8{ "focus", "zoom", "scroll", "select_window", "select_pane" }) |word| try expect(std.mem.indexOf(u8, v.name, word) == null);
        for (v.params) |p| for ([_][]const u8{ "focus", "zoom", "scroll", "active_window", "client" }) |word| try expect(!std.mem.eql(u8, p.name, word));
    }
}
fn countVerb(app: *const App, verb: []const u8) usize {
    var n: usize = 0;
    for (app.requests.items) |r| n += @intFromBool(std.mem.eql(u8, r.verb, verb));
    return n;
}

test "a segment shows on both clients, is truncated by priority at 80 columns, and goes when its connection closes" {
    const d = try Daemon.create();
    defer d.destroy();
    try topology(d);
    const venom = try d.principal(&.{ .{ .right = .write, .scope = "server:root" }, .{ .right = .read, .scope = "*" } }, "venom");
    var conn = d.connection(venom);
    try d.ok(&conn, "status.set", "{\"id\":\"venom.agents\",\"text\":\"2 running · 1 waiting\",\"priority\":50,\"style\":\"warn\"}");
    try d.ok(&conn, "status.set", "{\"id\":\"venom.log\",\"text\":\"thread-7: running tests in packages/core, 412 of 980 done\",\"priority\":20,\"side\":\"left\"}");
    // A daemon-bound segment outlives the connection.
    try d.ok(&conn, "status.set", "{\"id\":\"venom.mode\",\"text\":\"host\",\"priority\":40,\"bind\":\"daemon\"}");
    var wide = try Client.init(160, 10);
    defer wide.deinit();
    var narrow = try Client.init(80, 10);
    defer narrow.deinit();
    try wide.sync(d);
    try narrow.sync(d);
    const w = try wide.status();
    defer a.free(w);
    const n = try narrow.status();
    defer a.free(n);
    // Both show it, with the warn glyph (state is not colour alone).
    try expect(std.mem.indexOf(u8, w, "▲ 2 running · 1 waiting") != null);
    try expect(std.mem.indexOf(u8, n, "▲ 2 running · 1 waiting") != null);
    // 160 columns fit everything whole, the clock included.
    try expect(std.mem.indexOf(u8, w, "412 of 980 done") != null);
    try expect(std.mem.indexOf(u8, w, "14:02") != null);
    // 80 columns: the lowest-priority segments go first; the last one
    // placed (venom.log, 20) is truncated with an ellipsis and the clock
    // (10) is dropped.
    try expect(std.mem.indexOf(u8, n, "thread-7") != null);
    try expect(std.mem.indexOf(u8, n, "…") != null);
    try expect(std.mem.indexOf(u8, n, "412 of 980 done") == null);
    try expect(std.mem.indexOf(u8, n, "14:02") == null);
    try expect(std.mem.indexOf(u8, n, " s0 ") != null);
    // venom's connection closes: its connection-bound segments go.
    d.server.closed(&conn);
    conn.deinit();
    try wide.sync(d);
    try narrow.sync(d);
    for ([_]*Client{ &wide, &narrow }) |c| {
        const s = try c.status();
        defer a.free(s);
        try expect(std.mem.indexOf(u8, s, "running") == null);
        try expect(std.mem.indexOf(u8, s, "thread-7") == null);
        try expect(std.mem.indexOf(u8, s, "host") != null);
    }
    const tail = d.events.entries.items[d.events.entries.items.len - 1];
    try expect(std.mem.indexOf(u8, tail.bytes, "\"reason\":\"disconnect\"") != null);
    // A late client's snapshot has only the surviving segment.
    var r = try d.call(&d.owner, "status.list", "{}");
    defer r.deinit();
    try expectEqual(@as(usize, 1), r.value.object.get("ok").?.object.get("segments").?.array.items.len);
}

test "a principal cannot set venomx.* or another namespace's segment" {
    const d = try Daemon.create();
    defer d.destroy();
    try d.ok(&d.owner, "session.create", "{}");
    const grants = [_]g.Grant{ .{ .right = .write, .scope = "*" }, .{ .right = .read, .scope = "*" } };
    var venom = d.connection(try d.principal(&grants, "venom"));
    defer venom.deinit();
    var other = d.connection(try d.principal(&grants, "venom-os"));
    defer other.deinit();
    var plain = d.connection(try d.principal(&grants, null));
    defer plain.deinit();
    const set = "status.set";
    try expectEqualStrings("denied.namespace", try d.code(&venom, set, "{\"id\":\"venomx.clock\",\"text\":\"x\"}"));
    try expectEqualStrings("denied.namespace", try d.code(&venom, set, "{\"id\":\"venom-os.launcher\",\"text\":\"x\"}"));
    try expectEqualStrings("denied.namespace", try d.code(&venom, set, "{\"id\":\"user.x\",\"text\":\"x\"}"));
    try expectEqualStrings("ok", try d.code(&venom, set, "{\"id\":\"venom.agents\",\"text\":\"x\",\"bind\":\"daemon\"}"));
    // Another namespace can neither replace nor clear it.
    try expectEqualStrings("denied.namespace", try d.code(&other, set, "{\"id\":\"venom.agents\",\"text\":\"mine now\"}"));
    try expectEqualStrings("denied.namespace", try d.code(&other, "status.clear", "{\"id\":\"venom.agents\"}"));
    try expectEqualStrings("ok", try d.code(&other, set, "{\"id\":\"venom-os.launcher\",\"text\":\"x\"}"));
    // The owner's namespace is venomx: built-ins stay reserved, user.* is its own.
    try expectEqualStrings("denied.namespace", try d.code(&d.owner, set, "{\"id\":\"venomx.attention\",\"text\":\"x\"}"));
    try expectEqualStrings("denied.namespace", try d.code(&d.owner, set, "{\"id\":\"venom.agents\",\"text\":\"x\"}"));
    try expectEqualStrings("ok", try d.code(&d.owner, set, "{\"id\":\"user.note\",\"text\":\"x\"}"));
    // A principal with no namespace is `user`.
    try expectEqualStrings("ok", try d.code(&plain, set, "{\"id\":\"user.other\",\"text\":\"x\"}"));
    try expectEqualStrings("denied.namespace", try d.code(&plain, set, "{\"id\":\"venom.agents\",\"text\":\"x\"}"));
    // Bad ids and text are invalid_params.segment, never a namespace hit.
    try expectEqualStrings("invalid_params.segment", try d.code(&venom, set, "{\"id\":\"agents\",\"text\":\"x\"}"));
    try expectEqualStrings("invalid_params.segment", try d.code(&venom, set, "{\"id\":\"venom.a\",\"text\":\"a\\u001bb\"}"));
    // The segment kept venom's content.
    var r = try d.call(&d.owner, "status.list", "{}");
    defer r.deinit();
    for (r.value.object.get("ok").?.object.get("segments").?.array.items) |s| if (std.mem.eql(u8, s.object.get("id").?.string, "venom.agents")) try expectEqualStrings("x", s.object.get("text").?.string);
    // A principal without write on the scope is denied before anything else.
    var reader = d.connection(try d.principal(&.{.{ .right = .read, .scope = "*" }}, "venom"));
    defer reader.deinit();
    try expectEqualStrings("denied.write", try d.code(&reader, set, "{\"id\":\"venom.agents\",\"text\":\"y\"}"));
}

test "product attention marks the pane on every client and the focusing client clears it" {
    const d = try Daemon.create();
    defer d.destroy();
    try topology(d);
    const venom = try d.principal(&.{ .{ .right = .write, .scope = "session:s0" }, .{ .right = .read, .scope = "*" } }, "venom");
    var conn = d.connection(venom);
    defer conn.deinit();
    var one = try Client.init(80, 12);
    defer one.deinit();
    var two = try Client.init(80, 12);
    defer two.deinit();
    try one.sync(d);
    try two.sync(d);
    try d.ok(&conn, "pane.attention", "{\"pane\":\"p1\",\"level\":\"urgent\",\"reason\":\"approval: rm -rf build/\"}");
    try one.sync(d);
    try two.sync(d);
    for ([_]*Client{ &one, &two }) |c| {
        const all = try c.screen();
        defer a.free(all);
        // The marker is on p1's title line, the row above its rectangle:
        // `▲` after its title (no pane ID), with no label over the pane.
        var rows = std.mem.splitScalar(u8, all, '\n');
        for (0..c.app.pane("p1").?.rect.y - 1) |_| _ = rows.next();
        const line = rows.next().?;
        try expect(std.mem.indexOf(u8, line, "─ true ▲ ─") != null);
        try expect(std.mem.indexOf(u8, all, "urgent") == null);
        const s = try c.status();
        defer a.free(s);
        try expect(std.mem.indexOf(u8, s, "▲ 1 attention") != null);
        // Nobody's focus moved.
        try expectEqualStrings("p0", c.app.focus.?);
    }
    // Client one focuses p1: it clears attention under its own identity.
    try one.app.run(.{ .local = .focus_attention });
    try expectEqualStrings("p1", one.app.focus.?);
    try expectEqual(@as(usize, 1), countVerb(&one.app, "pane.attention"));
    try expectEqual(@as(usize, 0), countVerb(&two.app, "pane.attention"));
    var owner_client = d.connection(g.owner);
    defer owner_client.deinit();
    try one.flush(d, &owner_client);
    try one.sync(d);
    try two.sync(d);
    for ([_]*Client{ &one, &two }) |c| {
        const all = try c.screen();
        defer a.free(all);
        try expect(std.mem.indexOf(u8, all, "urgent") == null);
        try expect(std.mem.indexOf(u8, all, "attention") == null);
    }
    try expectEqualStrings("p0", two.app.focus.?);
    // With attention.sticky the focusing client leaves it set.
    try d.ok(&conn, "pane.attention", "{\"pane\":\"p0\",\"level\":\"warn\"}");
    try two.sync(d);
    try two.app.shared.applyConfig("attention", ".{ .sticky = true }");
    try two.app.run(.{ .local = .focus_next });
    try two.app.run(.{ .local = .focus_prev });
    try expectEqual(@as(usize, 0), countVerb(&two.app, "pane.attention"));
}

test "info attention on the pane a client is focused on is cleared by that client alone" {
    const d = try Daemon.create();
    defer d.destroy();
    try topology(d);
    const p0 = d.product.pane("p0").?;
    var one = try Client.init(80, 12);
    defer one.deinit();
    var two = try Client.init(80, 12);
    defer two.deinit();
    try one.sync(d);
    try two.sync(d);
    try two.app.run(.{ .local = .focus_next });
    try expectEqualStrings("p0", one.app.focus.?);
    try expectEqualStrings("p1", two.app.focus.?);
    var owner_client = d.connection(g.owner);
    defer owner_client.deinit();
    // A BEL in p0: only the client focused on it clears it, and until that
    // clear lands the other client shows the marker.
    try p0.pane.vt.feed("\x07");
    try chrome.observe(&d.product, p0);
    try one.sync(d);
    try two.sync(d);
    try expectEqual(@as(usize, 1), countVerb(&one.app, "pane.attention"));
    try expectEqual(@as(usize, 0), countVerb(&two.app, "pane.attention"));
    const before = try two.status();
    defer a.free(before);
    try expect(std.mem.indexOf(u8, before, "▲ 1 attention") != null);
    try one.flush(d, &owner_client);
    try one.sync(d);
    try two.sync(d);
    try expectEqual(chrome.Level.none, p0.attention.level);
    for ([_]*Client{ &one, &two }) |c| {
        const all = try c.screen();
        defer a.free(all);
        try expect(std.mem.indexOf(u8, all, "info") == null);
        try expect(std.mem.indexOf(u8, all, "attention") == null);
    }
    // The clear's own `none` event asks for nothing further.
    try expectEqual(@as(usize, 0), countVerb(&one.app, "pane.attention"));
    try expectEqual(@as(usize, 0), countVerb(&two.app, "pane.attention"));

    // A blocked report is the same observation. Sticky keeps it on the focused
    // client, and the other client still clears it by focusing the pane.
    try one.app.shared.applyConfig("attention", ".{ .sticky = true }");
    try p0.pane.vt.feed("\x1b]7501;state=blocked:app=build\x07");
    try chrome.observe(&d.product, p0);
    try one.sync(d);
    try two.sync(d);
    try expectEqual(@as(usize, 0), countVerb(&one.app, "pane.attention"));
    const kept = try one.status();
    defer a.free(kept);
    try expect(std.mem.indexOf(u8, kept, "▲ 1 attention") != null);
    try two.app.run(.{ .local = .focus_prev });
    try expectEqual(@as(usize, 1), countVerb(&two.app, "pane.attention"));
    try two.flush(d, &owner_client);
    try one.sync(d);
    try two.sync(d);
    try expectEqual(chrome.Level.none, p0.attention.level);

    // Product levels stay on the focused pane, with or without sticky.
    try one.app.shared.applyConfig("attention", ".{ .sticky = false }");
    for ([_][]const u8{ "warn", "urgent" }) |level| {
        const params = try std.fmt.allocPrint(a, "{{\"pane\":\"p0\",\"level\":\"{s}\",\"reason\":\"look\"}}", .{level});
        defer a.free(params);
        try d.ok(&d.owner, "pane.attention", params);
        try one.sync(d);
        try two.sync(d);
        try expectEqual(@as(usize, 0), countVerb(&one.app, "pane.attention"));
        try expectEqual(@as(usize, 0), countVerb(&two.app, "pane.attention"));
        const all = try one.screen();
        defer a.free(all);
        // The mark is on the pane's title line.
        try expect(std.mem.indexOf(u8, all, "━ true ▲ ━") != null);
    }
}

test "an owner-created pane reads as venomx in grant.list, and gains nothing from it" {
    const d = try Daemon.create();
    defer d.destroy();
    try topology(d);
    const pane_id = d.product.pane("p0").?.principal;
    // Its program may exit at any moment; keep the principal live regardless.
    d.registry.entries.items[@intCast(pane_id)].root = null;
    // grant.list, the surface the grant rules are checked against.
    var listed = try d.call(&d.owner, "grant.list", "{}");
    defer listed.deinit();
    var buf: [24]u8 = undefined;
    const name = g.name(pane_id, &buf);
    var found = false;
    for (listed.value.object.get("ok").?.object.get("principals").?.array.items) |entry| {
        if (!std.mem.eql(u8, entry.object.get("principal").?.string, name)) continue;
        found = true;
        try expectEqualStrings("pane", entry.object.get("kind").?.string);
        try expectEqualStrings("venomx", entry.object.get("namespace").?.string);
    }
    try expect(found);
    // The default rights are unchanged: nothing is reachable through the namespace.
    const rights = d.registry.get(pane_id).?.grants;
    try expectEqual(d.registry.policy.interactive.len, rights.len);
    for (d.registry.policy.interactive, rights) |want, got| {
        try expectEqual(want.right, got.right);
        try expectEqualStrings(want.scope, got.scope);
    }
    var pane = d.connection(pane_id);
    defer pane.deinit();
    try expectEqualStrings("denied.write", try d.code(&pane, "status.set", "{\"id\":\"user.x\",\"text\":\"x\"}"));
    // Even with write on server:root, venomx.* stays reserved and other
    // namespaces stay closed. user.* stays open, as it was when the pane read as user.
    const write_root = [_]g.Grant{.{ .right = .write, .scope = "server:root" }};
    d.registry.entries.items[@intCast(pane_id)].grants = &write_root;
    try expectEqualStrings("denied.namespace", try d.code(&pane, "status.set", "{\"id\":\"venomx.clock\",\"text\":\"x\"}"));
    try expectEqualStrings("denied.namespace", try d.code(&pane, "status.set", "{\"id\":\"venom.agents\",\"text\":\"x\"}"));
    try expectEqualStrings("ok", try d.code(&pane, "status.set", "{\"id\":\"user.note\",\"text\":\"x\"}"));
    // A token the owner issues without a namespace is still `user`.
    try expectEqualStrings("user", d.registry.namespaceOf(try d.principal(&.{}, null)));
}

test "pane tags: owner from the creator's namespace, read-only, limits, events and snapshot" {
    const d = try Daemon.create();
    defer d.destroy();
    try topology(d);
    const venom = try d.principal(&.{ .{ .right = .write, .scope = "*" }, .{ .right = .spawn, .scope = "*" }, .{ .right = .read, .scope = "*" } }, "venom");
    var conn = d.connection(venom);
    defer conn.deinit();
    try d.ok(&conn, "pane.split", "{\"pane\":\"p1\",\"axis\":\"rows\",\"argv\":[\"true\"],\"tags\":[{\"key\":\"role\",\"value\":\"control\"}]}");
    try expectEqualStrings("venomx", d.product.pane("p0").?.tags.get("owner").?);
    try expectEqualStrings("venom", d.product.pane("p3").?.tags.get("owner").?);
    try expectEqualStrings("control", d.product.pane("p3").?.tags.get("role").?);
    try expectEqualStrings("invalid_params.tags", try d.code(&conn, "pane.tag", "{\"pane\":\"p3\",\"set\":[{\"key\":\"owner\",\"value\":\"me\"}]}"));
    try expectEqualStrings("invalid_params.tags", try d.code(&conn, "pane.tag", "{\"pane\":\"p3\",\"unset\":[\"owner\"]}"));
    try expectEqualStrings("invalid_params.tags", try d.code(&conn, "pane.tag", "{\"pane\":\"p3\",\"set\":[{\"key\":\"Bad\",\"value\":\"x\"}]}"));
    try expectEqualStrings("invalid_params.tags", try d.code(&conn, "pane.split", "{\"pane\":\"p1\",\"axis\":\"rows\",\"argv\":[\"true\"],\"tags\":[{\"key\":\"owner\",\"value\":\"x\"}]}"));
    // 16 tags at most, owner included.
    var many: std.ArrayList(u8) = .empty;
    defer many.deinit(a);
    try many.appendSlice(a, "{\"pane\":\"p3\",\"set\":[");
    for (0..15) |i| try many.print(a, "{s}{{\"key\":\"k{d}\",\"value\":\"v\"}}", .{ if (i > 0) "," else "", i });
    try many.appendSlice(a, "]}");
    try expectEqualStrings("invalid_params.tags", try d.code(&conn, "pane.tag", many.items));
    const high = d.events.high;
    try d.ok(&conn, "pane.tag", "{\"pane\":\"p3\",\"set\":[{\"key\":\"group\",\"value\":\"thread-7\"}],\"unset\":[\"role\"]}");
    try expectEqual(high + 1, d.events.high);
    // An unchanged tag map emits nothing.
    try d.ok(&conn, "pane.tag", "{\"pane\":\"p3\",\"set\":[{\"key\":\"group\",\"value\":\"thread-7\"}]}");
    try expectEqual(high + 1, d.events.high);
    const last = d.events.entries.items[d.events.entries.items.len - 1].bytes;
    try expect(std.mem.indexOf(u8, last, "\"type\":\"pane.tags_changed\"") != null);
    try expect(std.mem.indexOf(u8, last, "\"revision\":1") != null);
    var list = try d.call(&d.owner, "pane.list", "{}");
    defer list.deinit();
    try expect(std.mem.indexOf(u8, d.owner.output.items, "{\"key\":\"group\",\"value\":\"thread-7\"},{\"key\":\"owner\",\"value\":\"venom\"}") != null);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var found = false;
    for (try d.product.capture(arena.allocator())) |e| if (std.mem.eql(u8, e.resource, "pane:p3")) {
        found = std.mem.indexOf(u8, e.content, "thread-7") != null;
    };
    try expect(found);
    // A client sees tags through `when`: the segment shows only on p3.
    try d.ok(&conn, "status.set", "{\"id\":\"venom.thread\",\"text\":\"thread-7 view\",\"when\":[{\"key\":\"group\",\"value\":\"thread-7\"}]}");
    var c = try Client.init(100, 12);
    defer c.deinit();
    try c.sync(d);
    const before = try c.status();
    defer a.free(before);
    try expect(std.mem.indexOf(u8, before, "thread-7 view") == null);
    try c.app.run(.{ .local = .focus_next });
    try c.app.run(.{ .local = .focus_next });
    try expectEqualStrings("p3", c.app.focus.?);
    const after = try c.status();
    defer a.free(after);
    try expect(std.mem.indexOf(u8, after, "thread-7 view") != null);
}

test "pane.created carries tags: a client attached before a tagged pane matches its `when` table" {
    const d = try Daemon.create();
    defer d.destroy();
    try topology(d);
    const venom = try d.principal(&.{ .{ .right = .write, .scope = "*" }, .{ .right = .spawn, .scope = "*" }, .{ .right = .read, .scope = "*" } }, "venom");
    var conn = d.connection(venom);
    defer conn.deinit();
    try d.ok(&conn, "status.set", "{\"id\":\"venom.thread\",\"text\":\"thread-9 view\",\"when\":[{\"key\":\"group\",\"value\":\"thread-9\"}]}");
    // The client attaches first; the tagged pane appears afterwards.
    var c = try Client.init(100, 12);
    defer c.deinit();
    try c.sync(d);
    const high = d.events.high;
    try d.ok(&conn, "pane.split", "{\"pane\":\"p1\",\"axis\":\"rows\",\"argv\":[\"true\"],\"tags\":[{\"key\":\"group\",\"value\":\"thread-9\"}]}");
    // No pane.tags_changed follows: pane.created alone carries the tags.
    for (d.events.entries.items[@intCast(high)..]) |e| try expect(std.mem.indexOf(u8, e.bytes, "pane.tags_changed") == null);
    try c.sync(d);
    try c.app.run(.{ .local = .focus_next });
    try c.app.run(.{ .local = .focus_next });
    try expectEqualStrings("p3", c.app.focus.?);
    const shown = try c.status();
    defer a.free(shown);
    try expect(std.mem.indexOf(u8, shown, "thread-9 view") != null);
}

test "segment limits, scope, ttl, revocation; notification queue and dismissal" {
    const d = try Daemon.create();
    defer d.destroy();
    try topology(d);
    const id = try d.principal(&.{ .{ .right = .write, .scope = "*" }, .{ .right = .read, .scope = "*" } }, "venom");
    var conn = d.connection(id);
    defer conn.deinit();
    var buf: [128]u8 = undefined;
    for (0..chrome.max_segments_per_namespace) |i| try d.ok(&conn, "status.set", try std.fmt.bufPrint(&buf, "{{\"id\":\"venom.s{d}\",\"text\":\"x\"}}", .{i}));
    try expectEqualStrings("conflict.segment_limit", try d.code(&conn, "status.set", "{\"id\":\"venom.more\",\"text\":\"x\"}"));
    // Replacing an existing id is not a new segment.
    try expectEqualStrings("ok", try d.code(&conn, "status.set", "{\"id\":\"venom.s0\",\"text\":\"y\"}"));
    try d.ok(&conn, "status.clear", "{\"id\":\"venom.s1\"}");
    try expectEqualStrings("not_found.segment", try d.code(&conn, "status.clear", "{\"id\":\"venom.s1\"}"));
    // A session-scoped segment needs write on that session and shows only
    // on clients of that session.
    const session_only = try d.principal(&.{ .{ .right = .write, .scope = "session:s0" }, .{ .right = .read, .scope = "*" } }, "venom-os");
    var scoped = d.connection(session_only);
    defer scoped.deinit();
    try expectEqualStrings("denied.write", try d.code(&scoped, "status.set", "{\"id\":\"venom-os.x\",\"text\":\"x\"}"));
    try d.ok(&scoped, "status.set", "{\"id\":\"venom-os.x\",\"text\":\"s0 only\",\"scope\":\"s0\",\"ttl_ms\":1000}");
    var c = try Client.init(120, 6);
    defer c.deinit();
    try c.sync(d);
    const shown = try c.status();
    defer a.free(shown);
    try expect(std.mem.indexOf(u8, shown, "s0 only") != null);
    // ttl: the daemon drops it once it expires.
    d.product.chrome.segment("venom-os.x").?.expires = 0;
    chrome.tick(&d.product);
    try expect(d.product.chrome.segment("venom-os.x") == null);
    try expect(std.mem.indexOf(u8, d.events.entries.items[d.events.entries.items.len - 1].bytes, "\"reason\":\"ttl\"") != null);
    // Revoking the setter drops its daemon-bound segments.
    try d.ok(&conn, "status.set", "{\"id\":\"venom.kept\",\"text\":\"x\",\"bind\":\"daemon\"}");
    try d.registry.revoke(.{ .principal = g.owner }, id, g.nowSeconds());
    chrome.tick(&d.product);
    try expect(d.product.chrome.segment("venom.kept") == null);
    try expect(std.mem.indexOf(u8, d.events.entries.items[d.events.entries.items.len - 1].bytes, "\"reason\":\"revoked\"") != null);
    // Notifications: a queue of 64, oldest dropped.
    var poster = d.connection(try d.principal(&.{ .{ .right = .write, .scope = "server:root" }, .{ .right = .read, .scope = "*" } }, "venom"));
    defer poster.deinit();
    for (0..chrome.max_notifications + 3) |i| try d.ok(&poster, "notify.post", try std.fmt.bufPrint(&buf, "{{\"text\":\"note {d}\"}}", .{i}));
    try expectEqual(@as(usize, chrome.max_notifications), d.product.chrome.notifications.items.len);
    try expectEqualStrings("n3", d.product.chrome.notifications.items[0].id);
    // Local dismissal hides it only for that connection.
    try d.ok(&poster, "notify.dismiss", "{\"id\":\"n66\"}");
    var mine = try d.call(&poster, "notify.list", "{}");
    defer mine.deinit();
    try expectEqual(@as(usize, 63), mine.value.object.get("ok").?.object.get("notifications").?.array.items.len);
    var theirs = try d.call(&d.owner, "notify.list", "{}");
    defer theirs.deinit();
    try expectEqual(@as(usize, 64), theirs.value.object.get("ok").?.object.get("notifications").?.array.items.len);
    // all=true needs write and removes it for everyone.
    var reader = d.connection(try d.principal(&.{.{ .right = .read, .scope = "*" }}, null));
    defer reader.deinit();
    try expectEqualStrings("denied.write", try d.code(&reader, "notify.dismiss", "{\"id\":\"n65\",\"all\":true}"));
    try d.ok(&poster, "notify.dismiss", "{\"id\":\"n65\",\"all\":true}");
    try expectEqualStrings("not_found.notification", try d.code(&d.owner, "notify.dismiss", "{\"id\":\"n65\"}"));
    // The client shows the newest one in its status line until its TTL
    // (another connection's local dismissal does not reach it; all=true does).
    try c.sync(d);
    const noted = try c.status();
    defer a.free(noted);
    try expect(std.mem.indexOf(u8, noted, "◆ note 66") != null);
    try expect(c.app.shared.notes.items.len == 63);
    c.app.fixed_now = 1000 + 8000;
    const expired = try c.status();
    defer a.free(expired);
    try expect(std.mem.indexOf(u8, expired, "note") == null);
    // Attention: exactly one of level or clear.
    try expectEqualStrings("invalid_params.attention", try d.code(&d.owner, "pane.attention", "{\"pane\":\"p0\"}"));
    try expectEqualStrings("invalid_params.attention", try d.code(&d.owner, "pane.attention", "{\"pane\":\"p0\",\"level\":\"info\",\"clear\":true}"));
}

test "window entries draw index:name (1-based), the index alone for an unnamed window" {
    var c = try Client.init(80, 6);
    defer c.deinit();
    try c.app.control("{\"id\":2,\"item\":{\"type\":\"window.created\",\"data\":{\"window\":\"w0\",\"session\":\"s0\",\"name\":\"shell\",\"revision\":1,\"nodes\":[{\"kind\":\"pane\",\"pane\":\"p0\"}]}}}");
    try c.app.control("{\"id\":2,\"item\":{\"type\":\"window.created\",\"data\":{\"window\":\"w1\",\"session\":\"s0\",\"name\":\"my agents\",\"revision\":1,\"nodes\":[{\"kind\":\"pane\",\"pane\":\"p1\"}]}}}");
    try c.app.control("{\"id\":2,\"item\":{\"type\":\"window.created\",\"data\":{\"window\":\"w2\",\"session\":\"s0\",\"name\":\"\",\"revision\":1,\"nodes\":[{\"kind\":\"pane\",\"pane\":\"p2\"}]}}}");
    // layout_changed carries no name; the window keeps the one it was created with.
    try c.app.control("{\"id\":2,\"item\":{\"type\":\"window.layout_changed\",\"data\":{\"window\":\"w0\",\"session\":\"s0\",\"revision\":2,\"nodes\":[{\"kind\":\"pane\",\"pane\":\"p0\"}]}}}");
    try c.app.run(.{ .local = .window_2 });
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    // The entries are the windows alone; no pane rides on the active one.
    try expectEqualStrings("1:shell ▸2:my\u{a0}agents 3", try windowsItem(&c.app, arena.allocator()));
}

test "leader N selects the window drawn with index N" {
    var c = try Client.init(80, 6);
    defer c.deinit();
    try c.app.control("{\"id\":2,\"item\":{\"type\":\"window.created\",\"data\":{\"window\":\"w0\",\"session\":\"s0\",\"name\":\"shell\",\"revision\":1,\"nodes\":[{\"kind\":\"pane\",\"pane\":\"p0\"}]}}}");
    try c.app.control("{\"id\":2,\"item\":{\"type\":\"window.created\",\"data\":{\"window\":\"w1\",\"session\":\"s0\",\"name\":\"logs\",\"revision\":1,\"nodes\":[{\"kind\":\"pane\",\"pane\":\"p1\"}]}}}");
    try c.app.control("{\"id\":2,\"item\":{\"type\":\"window.created\",\"data\":{\"window\":\"w2\",\"session\":\"s0\",\"name\":\"\",\"revision\":1,\"nodes\":[{\"kind\":\"pane\",\"pane\":\"p2\"}]}}}");
    const ids = [_][]const u8{ "w0", "w1", "w2" };
    inline for (.{ .window_1, .window_2, .window_3 }, ids, 1..) |l, id, n| {
        try c.app.run(.{ .local = l });
        try expectEqualStrings(id, c.app.active.?);
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const items = try c.app.statusItems(arena.allocator());
        var want: [8]u8 = undefined;
        const mark = try std.fmt.bufPrint(&want, "▸{d}", .{n});
        for (items) |it| if (std.mem.eql(u8, it.id, "venomx.windows")) try expect(std.mem.indexOf(u8, it.text, mark) != null);
    }
}

const lone_window = "{\"id\":2,\"item\":{\"type\":\"window.created\",\"data\":{\"window\":\"w0\",\"session\":\"s0\",\"name\":\"shell\",\"revision\":1,\"nodes\":[{\"kind\":\"pane\",\"pane\":\"p0\"}]}}}";

fn windowsItem(app: *App, arena: std.mem.Allocator) ![]const u8 {
    for (try app.statusItems(arena)) |it| if (std.mem.eql(u8, it.id, "venomx.windows")) return it.text;
    return error.NoWindowsItem;
}

fn paneLive(app: *App, id: []const u8, cols: u16, rows: u16) !*@import("attach_app.zig").PaneView {
    const p = app.pane(id).?;
    p.stream.vt = try @import("vt").Vt.init(a, .{ .cols = cols, .rows = rows });
    p.stream.phase = .live;
    p.stream.writer = true;
    return p;
}

test "the window list is indexes alone; a lone pane's mark ends its block" {
    var c = try Client.init(80, 6);
    defer c.deinit();
    try c.app.control("{\"id\":2,\"item\":{\"type\":\"window.created\",\"data\":{\"window\":\"w1\",\"session\":\"s0\",\"name\":\"logs\",\"revision\":1,\"nodes\":[{\"kind\":\"pane\",\"pane\":\"p1\"}]}}}");
    try c.app.control(lone_window);
    try c.app.run(.{ .local = .window_1 });
    try c.app.control("{\"id\":2,\"item\":{\"type\":\"pane.attention_changed\",\"data\":{\"pane\":\"p0\",\"level\":\"warn\",\"reason\":\"\",\"revision\":1}}}");
    const all = try c.screen();
    defer a.free(all);
    // A pane with no cwd or process shows its ID in its block.
    try expect(std.mem.startsWith(u8, screenRow(all, 0), " s0 ◤  ▸1:shell 2:logs │  p0 ▲  "));
    // The mark is data, not parsed from a title: a title ending in `▲` is no mark.
    var odd = try Client.init(80, 6);
    defer odd.deinit();
    try odd.app.control(lone_window);
    const o = try paneLive(&odd.app, "p0", 80, 4);
    try o.stream.vt.?.feed("\x1b]2;up \xe2\x96\xb2\x07");
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    _ = try odd.app.statusItems(arena.allocator());
    try expectEqual(@as(usize, 1), odd.app.pane_blocks.len);
    try expectEqualStrings("up ▲", odd.app.pane_blocks[0].process);
    try expect(odd.app.pane_blocks[0].mark == null);
}

test "an idle lone pane shows no mark" {
    var c = try Client.init(80, 6);
    defer c.deinit();
    try c.app.control("{\"id\":2,\"item\":{\"type\":\"pane.created\",\"data\":{\"pane\":\"p0\",\"session\":\"s0\",\"argv0\":\"zsh\"}}}");
    try c.app.control(lone_window);
    const all = try c.screen();
    defer a.free(all);
    const row = screenRow(all, 0);
    try expect(std.mem.startsWith(u8, row, " s0 ◤  ▸1:shell │  zsh  "));
    try expect(std.mem.indexOf(u8, row, "○") == null);
    try expect(std.mem.indexOf(u8, row, "p0") == null);
}

test "the pane blocks are the active window's panes in layout order, the focused one marked" {
    var c = try Client.init(80, 6);
    defer c.deinit();
    try c.app.control("{\"id\":2,\"item\":{\"type\":\"window.created\",\"data\":{\"window\":\"w0\",\"session\":\"s0\",\"name\":\"\",\"revision\":1,\"nodes\":[{\"kind\":\"split\",\"axis\":\"cols\",\"first\":1,\"second\":2},{\"kind\":\"pane\",\"pane\":\"p0\"},{\"kind\":\"pane\",\"pane\":\"p1\"}]}}}");
    {
        const all = try c.screen();
        defer a.free(all);
        try expect(std.mem.startsWith(u8, screenRow(all, 0), " s0 ◤  ▸1 │  p0   p1  "));
        try expect(c.app.pane_blocks.len == 0);
    }
    try c.app.run(.{ .local = .focus_next });
    const all = try c.screen();
    defer a.free(all);
    // Panes with title lines carry their marks there, not in the blocks.
    try expect(std.mem.startsWith(u8, screenRow(all, 0), " s0 ◤  ▸1 │  p0   p1    "));
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    _ = try c.app.statusItems(arena.allocator());
    try expect(!c.app.pane_blocks[0].focus and c.app.pane_blocks[1].focus);
}

test "the session block shows the session's name from the snapshot, else its ID" {
    var app = try App.init(a, .{ .session = "s0" }, .{ .cols = 60, .rows = 6 }, .{});
    defer app.deinit();
    app.fixed_clock = "14:02";
    app.fixed_now = 1000;
    try app.control("{\"id\":2,\"item\":{\"type\":\"state.snapshot\",\"data\":{\"entities\":[{\"entity_type\":\"session\",\"content\":\"{\\\"session\\\":\\\"s1\\\",\\\"name\\\":\\\"other\\\"}\"},{\"entity_type\":\"session\",\"content\":\"{\\\"session\\\":\\\"s0\\\",\\\"name\\\":\\\"my work\\\"}\"}]}}}");
    try app.control("{\"id\":2,\"item\":{\"type\":\"stream.checkpoint\",\"data\":{}}}");
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    for (try app.statusItems(arena.allocator())) |it| if (std.mem.eql(u8, it.id, "venomx.session")) try expectEqualStrings(" my work ", it.text);
    // An empty or blank name is the ID.
    try app.control("{\"id\":2,\"item\":{\"type\":\"state.snapshot\",\"data\":{\"entities\":[{\"entity_type\":\"session\",\"content\":\"{\\\"session\\\":\\\"s0\\\",\\\"name\\\":\\\"\\\\u3000\\\"}\"}]}}}");
    try app.control("{\"id\":2,\"item\":{\"type\":\"stream.checkpoint\",\"data\":{}}}");
    for (try app.statusItems(arena.allocator())) |it| if (std.mem.eql(u8, it.id, "venomx.session")) try expectEqualStrings(" s0 ", it.text);
}

test "a pane block shows its cwd and process, and is cut when narrow" {
    const setup = struct {
        fn client(cols: u16) !Client {
            var c = try Client.init(cols, 6);
            errdefer c.deinit();
            try c.app.control(lone_window);
            c.app.home = "/home/u";
            const p = try paneLive(&c.app, "p0", cols, 5);
            try p.stream.vt.?.feed("\x1b]7;file:///home/u/a-long-project-dir\x07\x1b]2;nvim\x07");
            return c;
        }
    };
    // Wide: ` ~/a-long-project-dir › nvim ` right after the window list.
    var wide = try setup.client(80);
    defer wide.deinit();
    const all = try wide.screen();
    defer a.free(all);
    try expect(std.mem.startsWith(u8, screenRow(all, 0), " s0 ◤  ▸1:shell │  ~/a-long-project-dir › nvim  "));
    // A deeper cwd loses its start.
    try wide.app.pane("p0").?.stream.vt.?.feed("\x1b]7;file:///home/u/src/a-long-project-dir\x07");
    const deep = try wide.screen();
    defer a.free(deep);
    try expect(std.mem.indexOf(u8, screenRow(deep, 0), " …/a-long-project-dir › nvim ") != null);
    // Narrower: the cwd gives way to the other items, the process stays.
    var small = try setup.client(40);
    defer small.deinit();
    const s = try small.screen();
    defer a.free(s);
    try expect(std.mem.indexOf(u8, screenRow(s, 0), "│  nvim  ") != null);
    try expect(std.mem.indexOf(u8, screenRow(s, 0), "project") == null);
    try expect(std.mem.endsWith(u8, screenRow(s, 0), "14:02"));
    // Narrower still: the blocks are cut with `…`, and the clock keeps its place.
    try small.app.pane("p0").?.stream.vt.?.feed("\x1b]2;a-very-long-program-name\x07");
    const t = try small.screen();
    defer a.free(t);
    try expect(std.mem.indexOf(u8, screenRow(t, 0), " a-very-long-pr…") != null);
    try expect(std.mem.endsWith(u8, screenRow(t, 0), "14:02"));
}

test "a login shell's argv0 is drawn without its dash" {
    var c = try Client.init(80, 6);
    defer c.deinit();
    try c.app.control("{\"id\":2,\"item\":{\"type\":\"pane.created\",\"data\":{\"pane\":\"p0\",\"session\":\"s0\",\"argv0\":\"-zsh\"}}}");
    try c.app.control(lone_window);
    const all = try c.screen();
    defer a.free(all);
    try expect(std.mem.indexOf(u8, screenRow(all, 0), " zsh ") != null);
    try expect(std.mem.indexOf(u8, screenRow(all, 0), "-zsh") == null);
}

test "with the status line off a lone pane's title change stays on the damage path" {
    var c = try Client.init(40, 6);
    defer c.deinit();
    try c.app.control(lone_window);
    const p = c.app.pane("p0").?;
    p.stream.vt = try @import("vt").Vt.init(a, .{ .cols = 40, .rows = 6 });
    p.stream.phase = .live;
    try c.app.shared.applyConfig("status", ".{ .position = .off }");
    try c.app.resize(40, 6);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var surface = try term.Surface.init(a, 40, 6);
    defer surface.deinit(&out.writer);
    try c.app.render(&surface);
    try p.stream.vt.?.feed("\x1b]2;new title\x07x");
    p.damaged = true;
    c.app.pane_damage = true;
    surface.damage = null;
    try c.app.render(&surface);
    const d = surface.damage.?;
    try expect(@as(u32, d.width) * d.height < @as(u32, 40) * 6);
}

test "window names arrive from the stream snapshot" {
    var app = try App.init(a, .{ .session = "s0" }, .{ .cols = 60, .rows = 6 }, .{});
    defer app.deinit();
    app.fixed_clock = "14:02";
    app.fixed_now = 1000;
    try app.control("{\"id\":2,\"item\":{\"type\":\"state.snapshot\",\"data\":{\"entities\":[{\"entity_type\":\"window\",\"content\":\"{\\\"window\\\":\\\"w0\\\",\\\"session\\\":\\\"s0\\\",\\\"name\\\":\\\"agents\\\",\\\"revision\\\":1,\\\"nodes\\\":[{\\\"kind\\\":\\\"pane\\\",\\\"pane\\\":\\\"p0\\\"}]}\"}]}}}");
    try app.control("{\"id\":2,\"item\":{\"type\":\"stream.checkpoint\",\"data\":{}}}");
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const items = try app.statusItems(arena.allocator());
    var found = false;
    for (items) |it| if (std.mem.eql(u8, it.id, "venomx.windows")) {
        found = true;
        try expect(std.mem.startsWith(u8, it.text, "▸1:agents"));
    };
    try expect(found);
}

test "a window name is cleaned, trimmed and cut at 16 cells" {
    var buf: [128]u8 = undefined;
    try expectEqualStrings("shell", windowLabel(&buf, "shell"));
    try expectEqualStrings("abcdefghijklmnop", windowLabel(&buf, "abcdefghijklmnopqrst"));
    // A width-2 character straddling cell 16 is dropped whole.
    try expectEqualStrings("aaaaaaaaaaaaaaa", windowLabel(&buf, "aaaaaaaaaaaaaaa世b"));
    // Past the 128-byte buffer.
    const long: [200]u8 = @splat('x');
    try expectEqualStrings("xxxxxxxxxxxxxxxx", windowLabel(&buf, &long));
    // Control characters are dropped; invalid UTF-8 bytes are dropped alone.
    try expectEqualStrings("ab", windowLabel(&buf, "a\nb"));
    try expectEqualStrings("ab", windowLabel(&buf, "ab\xff\xfe"));
    // Whitespace-only is the bare index.
    try expectEqualStrings("", windowLabel(&buf, "   "));
    try expectEqualStrings("a b", windowLabel(&buf, "  a b  "));
    // No visible cell is empty, whatever the space or zero-width character.
    try expectEqualStrings("", windowLabel(&buf, "\u{a0}"));
    try expectEqualStrings("", windowLabel(&buf, "\u{3000}"));
    try expectEqualStrings("", windowLabel(&buf, " \u{2003}\u{3000}\u{200b}"));
    try expectEqualStrings("a", windowLabel(&buf, "\u{3000}a\u{2009} "));
}

test "a whitespace-only Unicode window name draws the bare index" {
    var c = try Client.init(40, 6);
    defer c.deinit();
    try c.app.control("{\"id\":2,\"item\":{\"type\":\"window.created\",\"data\":{\"window\":\"w0\",\"session\":\"s0\",\"name\":\"\\u3000\\u00a0\",\"revision\":1,\"nodes\":[{\"kind\":\"pane\",\"pane\":\"p0\"}]}}}");
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    // No `:` after the index.
    try expectEqualStrings("\u{25b8}1", try windowsItem(&c.app, arena.allocator()));
}

fn statusItemsOnce(al: std.mem.Allocator, app: *App) !void {
    var arena = std.heap.ArenaAllocator.init(al);
    defer arena.deinit();
    _ = try app.statusItems(arena.allocator());
}

test "the status helpers return OutOfMemory at every allocation and leak nothing" {
    var c = try Client.init(70, 6);
    defer c.deinit();
    try c.app.control(lone_window);
    try std.testing.checkAllAllocationFailures(a, statusItemsOnce, .{&c.app});
}

test "status line config: position and slot overrides (.show, .priority) replace hide and priority" {
    var c = try Client.init(40, 6);
    defer c.deinit();
    try c.app.control("{\"id\":2,\"item\":{\"type\":\"window.created\",\"data\":{\"window\":\"w0\",\"session\":\"s0\",\"name\":\"\",\"revision\":1,\"nodes\":[{\"kind\":\"pane\",\"pane\":\"p0\"}]}}}");
    try c.app.control("{\"id\":2,\"item\":{\"type\":\"status.changed\",\"data\":{\"id\":\"venom.agents\",\"revision\":1,\"segment\":{\"id\":\"venom.agents\",\"text\":\"agents\",\"side\":\"right\",\"priority\":5,\"style\":\"normal\",\"when\":[],\"scope\":\"server\",\"bind\":\"connection\",\"revision\":1}}}}");
    // The clock (10) outranks the segment (5) on a narrow line, until the
    // config hides the clock and raises the segment.
    try c.app.shared.applyConfig("status", ".{ .position = .top, .segments = .{ .{ .id = \"venomx.clock\", .show = false }, .{ .id = \"venom.agents\", .priority = 99 } } }");
    try c.app.resize(40, 6);
    const all = try c.screen();
    defer a.free(all);
    const first = all[0..std.mem.indexOfScalar(u8, all, '\n').?];
    try expect(std.mem.indexOf(u8, first, "agents") != null);
    try expect(std.mem.indexOf(u8, first, "14:02") == null);
    try expectEqual(@as(u16, 1), c.app.pane("p0").?.rect.y);
    try c.app.shared.applyConfig("status", ".{ .position = .off }");
    try c.app.resize(40, 6);
    try expectEqual(@as(u16, 6), c.app.pane("p0").?.rect.height);
}

/// Answer the client's queued `config.get status` the way the daemon does.
fn answerStatusConfig(app: *App, content: []const u8) !void {
    var answered = false;
    var i: usize = 0;
    while (i < app.requests.items.len) {
        const r = app.requests.items[i];
        if (!std.mem.eql(u8, r.verb, "config.get") or std.mem.indexOf(u8, r.params, "\"status\"") == null) {
            i += 1;
            continue;
        }
        const reply = try std.json.Stringify.valueAlloc(a, .{ .id = r.id, .ok = .{ .key = "status", .content = content } }, .{});
        defer a.free(reply);
        a.free(r.params);
        _ = app.requests.orderedRemove(i);
        try app.control(reply);
        answered = true;
    }
    try expect(answered);
}

/// Row `y` of a rendered screen.
fn screenRow(all: []const u8, y: usize) []const u8 {
    var rows = std.mem.splitScalar(u8, all, '\n');
    for (0..y) |_| _ = rows.next();
    return rows.next() orelse "";
}

test "the status line is the top row by default and config changes move it live" {
    var c = try Client.init(40, 6);
    defer c.deinit();
    try c.app.control("{\"id\":2,\"item\":{\"type\":\"window.created\",\"data\":{\"window\":\"w0\",\"session\":\"s0\",\"name\":\"\",\"revision\":1,\"nodes\":[{\"kind\":\"pane\",\"pane\":\"p0\"}]}}}");
    const p0 = c.app.pane("p0").?;
    // Built-in default, before (or without) any daemon config.
    try expectEqual(chrome.StatusConfig.Position.top, (chrome.StatusConfig{}).position);
    try expectEqual(@as(?u16, 0), c.app.statusRow());
    try expectEqual(@as(u16, 1), p0.rect.y);
    try expectEqual(@as(u16, 5), p0.rect.height);
    {
        const all = try c.screen();
        defer a.free(all);
        try expect(std.mem.startsWith(u8, screenRow(all, 0), " s0 ◤  ▸1"));
        try expect(std.mem.indexOf(u8, screenRow(all, 5), " s0 ") == null);
    }
    // `config set status.position` emits config.changed; the client
    // re-reads `status` and moves the line without a restart.
    try c.app.control("{\"id\":2,\"item\":{\"type\":\"config.changed\",\"data\":{\"key\":\"status.position\"}}}");
    try answerStatusConfig(&c.app, ".{ .position = .bottom }");
    try expectEqual(@as(?u16, 5), c.app.statusRow());
    try expectEqual(@as(u16, 0), p0.rect.y);
    try expectEqual(@as(u16, 5), p0.rect.height);
    {
        const all = try c.screen();
        defer a.free(all);
        try expect(std.mem.startsWith(u8, screenRow(all, 5), " s0 ◤  ▸1"));
        try expect(std.mem.indexOf(u8, screenRow(all, 0), " s0 ") == null);
    }
    // And back to the top.
    try c.app.control("{\"id\":2,\"item\":{\"type\":\"config.changed\",\"data\":{\"key\":\"status.position\"}}}");
    try answerStatusConfig(&c.app, ".{ .position = .top }");
    try expectEqual(@as(?u16, 0), c.app.statusRow());
    try expectEqual(@as(u16, 1), p0.rect.y);
}

fn lastAttention(d: *Daemon) ?[]const u8 {
    var i = d.events.entries.items.len;
    while (i > d.events.head) {
        i -= 1;
        const bytes = d.events.entries.items[i].bytes;
        if (std.mem.indexOf(u8, bytes, "\"type\":\"pane.attention_changed\"") != null) return bytes;
    }
    return null;
}

test "a BEL or a blocked OSC 7501 report sets info attention with attention.from_bell" {
    const d = try Daemon.create();
    defer d.destroy();
    try topology(d);
    const p0 = d.product.pane("p0").?;
    const p1 = d.product.pane("p1").?;
    const p2 = d.product.pane("p2").?;
    // A BEL that terminates an OSC string is not a bell; output alone is nothing.
    try p0.pane.vt.feed("\x1b]0;title\x07plain output");
    try chrome.observe(&d.product, p0);
    try expectEqual(chrome.Level.none, p0.attention.level);
    try expect(lastAttention(d) == null);
    // A BEL from the program raises info attention once.
    try p0.pane.vt.feed("ding\x07\x07");
    try chrome.observe(&d.product, p0);
    try expectEqual(chrome.Level.info, p0.attention.level);
    try expectEqualStrings("bell", p0.attention.reason);
    try expectEqual(@as(u64, 1), p0.attention.revision);
    try expect(std.mem.indexOf(u8, lastAttention(d).?, "\"data\":{\"pane\":\"p0\",\"level\":\"info\",\"reason\":\"bell\",\"revision\":1}") != null);
    const seen = d.events.entries.items.len;
    try chrome.observe(&d.product, p0);
    try expectEqual(seen, d.events.entries.items.len);
    // It never replaces a level a product set, and a later bell does not
    // re-raise once that is cleared: the bell was consumed.
    try d.ok(&d.owner, "pane.attention", "{\"pane\":\"p1\",\"level\":\"urgent\",\"reason\":\"approve\"}");
    try p1.pane.vt.feed("\x07");
    try chrome.observe(&d.product, p1);
    try expectEqual(chrome.Level.urgent, p1.attention.level);
    try expectEqualStrings("approve", p1.attention.reason);
    try d.ok(&d.owner, "pane.attention", "{\"pane\":\"p1\",\"clear\":true}");
    try chrome.observe(&d.product, p1);
    try expectEqual(chrome.Level.none, p1.attention.level);
    // An OSC 7501 report that moves a record to blocked qualifies; working
    // does not, and repeating the same blocked report does not re-raise.
    try p2.pane.vt.feed("\x1b]7501;state=working:app=build\x07");
    try chrome.observe(&d.product, p2);
    try expectEqual(chrome.Level.none, p2.attention.level);
    try p2.pane.vt.feed("\x1b]7501;state=blocked:kind=permission:app=build\x07");
    try chrome.observe(&d.product, p2);
    try expectEqual(chrome.Level.info, p2.attention.level);
    try expectEqualStrings("program status: blocked", p2.attention.reason);
    try d.ok(&d.owner, "pane.attention", "{\"pane\":\"p2\",\"clear\":true}");
    try p2.pane.vt.feed("\x1b]7501;state=blocked:kind=permission:app=build\x07");
    try chrome.observe(&d.product, p2);
    try expectEqual(chrome.Level.none, p2.attention.level);
    // attention.from_bell = false: neither source raises attention.
    try d.ok(&d.owner, "pane.attention", "{\"pane\":\"p0\",\"clear\":true}");
    d.product.attention = .{ .from_bell = false };
    try p0.pane.vt.feed("\x07");
    try p2.pane.vt.feed("\x1b]7501;state=clear\x07\x1b]7501;state=blocked\x07");
    for ([_]*product_mod.Pane{ p0, p2 }) |p| {
        try chrome.observe(&d.product, p);
        try expectEqual(chrome.Level.none, p.attention.level);
    }
    // Nothing was left pending to fire once it is turned back on.
    d.product.attention = .{};
    try chrome.observe(&d.product, p0);
    try expectEqual(chrome.Level.none, p0.attention.level);
    // The config key defaults to true (test/daemon.py covers `config set`).
    try expect((chrome.AttentionConfig{}).from_bell);
}

test "pane.list: a live pane's process as (pid, start), gone once it exited" {
    const d = try Daemon.create();
    defer d.destroy();
    try topology(d);
    const entry = struct {
        fn of(x: *Daemon) !std.json.Parsed(Value) {
            return x.call(&x.owner, "pane.list", "{}");
        }
    }.of;
    var list = try entry(d);
    defer list.deinit();
    const panes = list.value.object.get("ok").?.object.get("panes").?.array.items;
    const p = d.product.panes.items[0];
    const pid = p.pane.pty.?.pid;
    try expectEqualStrings(p.id, panes[0].object.get("pane").?.string);
    try expectEqual(@as(i64, pid), panes[0].object.get("pid").?.integer);
    const root = d.registry.get(p.principal).?.root.?;
    try expectEqual(pid, root.pid);
    try expectEqual(@as(i64, @intCast(root.start)), panes[0].object.get("start").?.integer);

    const saved = p.pane.status;
    p.pane.status = .{ .code = 0 };
    defer p.pane.status = saved;
    var after = try entry(d);
    defer after.deinit();
    const gone = after.value.object.get("ok").?.object.get("panes").?.array.items[0].object;
    try expect(gone.get("pid") == null and gone.get("start") == null);
    try expect(gone.get("exited").?.bool);
}

test "argv0: the same value in pane.list, pane.created and the pane entity" {
    const d = try Daemon.create();
    defer d.destroy();
    try d.ok(&d.owner, "session.create", "{\"name\":\"work\"}");
    var long: [300]u8 = undefined;
    @memset(long[0..299], 'x');
    long[299] = 'y';
    var wide: [300]u8 = undefined;
    @memset(&wide, 'a');
    @memcpy(wide[254..256], "\u{e9}");
    const Case = struct { argv0: []const u8, want: ?[]const u8 };
    const cases = [_]Case{
        .{ .argv0 = "/usr/bin/nvim", .want = "nvim" },
        .{ .argv0 = "./run.sh", .want = "run.sh" },
        .{ .argv0 = "-sh", .want = "-sh" },
        .{ .argv0 = "/", .want = null },
        .{ .argv0 = "a/", .want = null },
        .{ .argv0 = &long, .want = long[0..255] },
        .{ .argv0 = &wide, .want = wide[0..254] },
    };
    for (cases) |c| {
        const params = try std.fmt.allocPrint(a, "{{\"session\":\"s0\",\"program\":\"true\",\"argv\":[\"{s}\"]}}", .{c.argv0});
        defer a.free(params);
        const high = d.events.high;
        try d.ok(&d.owner, "window.create", params);
        const pane = d.product.panes.items[d.product.panes.items.len - 1];
        // pane.created data.
        var seen = false;
        for (d.events.entries.items[@intCast(high)..]) |e| {
            if (std.mem.indexOf(u8, e.bytes, "\"pane.created\"") == null) continue;
            var ev = try std.json.parseFromSlice(Value, a, e.bytes, .{});
            defer ev.deinit();
            const got = ev.value.object.get("data").?.object.get("argv0");
            if (c.want) |w| try expectEqualStrings(w, got.?.string) else try expect(got == null);
            seen = true;
        }
        try expect(seen);
        // pane.list.
        var list = try d.call(&d.owner, "pane.list", "{}");
        defer list.deinit();
        const rows = list.value.object.get("ok").?.object.get("panes").?.array.items;
        var listed = false;
        for (rows) |row| if (std.mem.eql(u8, row.object.get("pane").?.string, pane.id)) {
            const got = row.object.get("argv0");
            if (c.want) |w| try expectEqualStrings(w, got.?.string) else try expect(got == null);
            listed = true;
        };
        try expect(listed);
        // The pane entity.
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var entity = false;
        for (try d.product.capture(arena.allocator())) |en| {
            if (!std.mem.eql(u8, en.entity_type, "pane") or std.mem.indexOf(u8, en.content, pane.id) == null) continue;
            var parsed = try std.json.parseFromSlice(Value, a, en.content, .{});
            defer parsed.deinit();
            if (!std.mem.eql(u8, parsed.value.object.get("pane").?.string, pane.id)) continue;
            const got = parsed.value.object.get("argv0");
            if (c.want) |w| try expectEqualStrings(w, got.?.string) else try expect(got == null);
            entity = true;
        }
        try expect(entity);
    }
}

fn screenHas(c: *Client, text: []const u8) !bool {
    const all = try c.screen();
    defer a.free(all);
    return std.mem.indexOf(u8, all, text) != null;
}

test "leader w: the window picker lists windows, enter switches this client only, esc closes" {
    const d = try Daemon.create();
    defer d.destroy();
    try topology(d);
    var one = try Client.init(80, 24);
    defer one.deinit();
    var two = try Client.init(80, 24);
    defer two.deinit();
    try one.sync(d);
    try two.sync(d);
    _ = try one.app.feedInput("\x02w");
    try expect(one.app.picker != null);
    try expect(try screenHas(&one, "windows"));
    try expect(try screenHas(&one, "w0* (active)  2 panes"));
    try expect(try screenHas(&one, "w1"));
    try expect(!try screenHas(&two, "windows"));
    // esc closes and changes nothing.
    try one.app.flushEscape();
    try expect(one.app.picker == null);
    try expect(!try screenHas(&one, "windows"));
    try expectEqualStrings("w0", one.app.active.?);
    // Keys go to the picker, not the pane, while it is open; enter switches.
    _ = try one.app.feedInput("\x02w");
    _ = try one.app.feedInput("j");
    try expectEqual(@as(usize, 1), one.app.picker.?.selected);
    _ = try one.app.feedInput("\r");
    try expect(one.app.picker == null);
    try expectEqualStrings("w1", one.app.active.?);
    try expectEqualStrings("w0", two.app.active.?);
    // The picker is client-local: it asks the daemon for nothing.
    for (one.app.requests.items) |r| try expect(!std.mem.startsWith(u8, r.verb, "window."));
}

/// Answer the client's last `session.list` request.
fn answerSessions(c: *Client) !void {
    const last = c.app.pending.items[c.app.pending.items.len - 1];
    try expectEqualStrings("session.list", last.verb);
    const line = try std.fmt.allocPrint(a, "{{\"id\":{d},\"ok\":{{\"sessions\":[{{\"session\":\"s1\",\"name\":\"play\"}},{{\"session\":\"s0\",\"name\":\"work\"}}]}}}}", .{last.id});
    defer a.free(line);
    try c.app.control(line);
}

test "leader s: the session picker lists sessions, enter re-attaches this client, esc closes" {
    const d = try Daemon.create();
    defer d.destroy();
    try topology(d);
    var one = try Client.init(80, 24);
    defer one.deinit();
    try one.sync(d);
    // The list is asked for, and shown when it arrives.
    _ = try one.app.feedInput("\x02s");
    try expect(one.app.picker == null);
    try answerSessions(&one);
    try expect(one.app.picker != null);
    try expect(try screenHas(&one, "sessions"));
    try expect(try screenHas(&one, "s1 play"));
    // IDs in order, this session selected.
    try expectEqualStrings("s0", one.app.picker.?.items.items[0].id);
    try expectEqual(@as(usize, 0), one.app.picker.?.selected);
    // esc closes and changes nothing.
    try one.app.flushEscape();
    try expect(one.app.picker == null);
    try expect(!try screenHas(&one, "sessions"));
    try expect(one.app.quit == null and one.app.switch_to == null);
    // Enter on the attached session is a no-op.
    _ = try one.app.feedInput("\x02s");
    try answerSessions(&one);
    _ = try one.app.feedInput("\r");
    try expect(one.app.picker == null and one.app.quit == null and one.app.switch_to == null);
    // Enter on another one asks the transport to attach there.
    _ = try one.app.feedInput("\x02s");
    try answerSessions(&one);
    _ = try one.app.feedInput("j\r");
    try expect(one.app.picker == null);
    try expectEqualStrings("s1", one.app.switch_to.?);
    try expect(one.app.quit != null);
}

test "a stale or repeated session.list reply opens no second picker" {
    const d = try Daemon.create();
    defer d.destroy();
    try topology(d);
    var one = try Client.init(80, 24);
    defer one.deinit();
    try one.sync(d);
    // leader s twice asks twice; the first reply opens the picker, the second is stale.
    _ = try one.app.feedInput("\x02s");
    _ = try one.app.feedInput("\x02s");
    const second = one.app.pending.items[one.app.pending.items.len - 1];
    try answerSessions(&one);
    try expect(one.app.picker != null);
    one.app.picker.?.selected = 0;
    const line = try std.fmt.allocPrint(a, "{{\"id\":{d},\"ok\":{{\"sessions\":[{{\"session\":\"s9\"}}]}}}}", .{second.id});
    defer a.free(line);
    try one.app.control(line);
    try expectEqual(@as(usize, 2), one.app.picker.?.items.items.len);
    // A reply that lands over the command prompt is dropped.
    try one.app.flushEscape();
    _ = try one.app.feedInput("\x02:");
    try expect(one.app.prompt != null);
    try one.app.control(line);
    try expect(one.app.picker == null and one.app.prompt != null);
}

test "a session.list error reply says so and opens nothing" {
    const d = try Daemon.create();
    defer d.destroy();
    try topology(d);
    var one = try Client.init(80, 24);
    defer one.deinit();
    try one.sync(d);
    _ = try one.app.feedInput("\x02s");
    const last = one.app.pending.items[one.app.pending.items.len - 1];
    const line = try std.fmt.allocPrint(a, "{{\"id\":{d},\"error\":{{\"code\":\"denied.read\"}}}}", .{last.id});
    defer a.free(line);
    try one.app.control(line);
    try expect(one.app.picker == null);
    try expectEqualStrings("session-picker: denied.read", one.app.message.items);
}

test "both pickers are local commands the prompt also takes" {
    const keys = @import("keys.zig");
    try expectEqualStrings("window-picker", keys.commandName(.{ .local = .window_picker }));
    try expectEqualStrings("session-picker", keys.commandName(.{ .local = .session_picker }));
    var found: usize = 0;
    for (keys.builtin_bindings) |b| {
        const name = keys.commandName(b.target.local);
        if (std.mem.eql(u8, name, "window-picker") or std.mem.eql(u8, name, "session-picker")) found += 1;
    }
    try expectEqual(@as(usize, 2), found);
}

test "the middle names the process in this order: current title, cmdline, process, argv0" {
    var c = try Client.init(80, 6);
    defer c.deinit();
    try c.app.control("{\"id\":2,\"item\":{\"type\":\"pane.created\",\"data\":{\"pane\":\"p0\",\"session\":\"s0\",\"argv0\":\"-zsh\"}}}");
    try c.app.control(lone_window);
    const p = try paneLive(&c.app, "p0", 80, 5);
    const Step = struct { event: ?[]const u8, feed: []const u8 = "", want: []const u8, not: ?[]const u8 = null };
    const steps = [_]Step{
        // A title nobody announced as current: argv0 (its dash dropped).
        .{ .event = null, .feed = "\x1b]2;old shell title\x07", .want = " zsh ", .not = "old shell title" },
        .{ .event = "{\"type\":\"pane.title_changed\",\"data\":{\"pane\":\"p0\",\"title\":\"old shell title\"}}", .want = "old shell title" },
        // The shell's command line makes the title stale and wins over the process.
        .{ .event = "{\"type\":\"command.started\",\"data\":{\"pane\":\"p0\",\"command\":\"p0/c0\",\"cmdline\":\"ping google.com\"}}", .want = "ping google.com" },
        .{ .event = "{\"type\":\"pane.process_changed\",\"data\":{\"pane\":\"p0\",\"process\":\"ping\"}}", .want = "ping google.com" },
        .{ .event = "{\"type\":\"command.finished\",\"data\":{\"pane\":\"p0\",\"command\":\"p0/c0\",\"reason\":\"osc133\",\"exit_code\":0}}", .want = " ping ", .not = "google" },
        // No shell integration: the sampled process.
        .{ .event = "{\"type\":\"pane.process_changed\",\"data\":{\"pane\":\"p0\",\"process\":\"codex\"}}", .want = " codex " },
        // The program's own title, set after it started, wins.
        .{ .event = "{\"type\":\"pane.title_changed\",\"data\":{\"pane\":\"p0\",\"title\":\"agent task\"}}", .feed = "\x1b]2;agent task\x07", .want = "agent task" },
        // The next process makes it stale; an absent process falls back to argv0.
        .{ .event = "{\"type\":\"pane.process_changed\",\"data\":{\"pane\":\"p0\",\"process\":\"zsh\"}}", .want = " zsh ", .not = "agent task" },
        .{ .event = "{\"type\":\"pane.process_changed\",\"data\":{\"pane\":\"p0\"}}", .want = " zsh ", .not = "agent task" },
    };
    for (steps) |s| {
        if (s.feed.len > 0) try p.stream.vt.?.feed(s.feed);
        if (s.event) |e| {
            const line = try std.fmt.allocPrint(a, "{{\"id\":2,\"item\":{s}}}", .{e});
            defer a.free(line);
            try c.app.control(line);
        }
        const all = try c.screen();
        defer a.free(all);
        const row = screenRow(all, 0);
        if (std.mem.indexOf(u8, row, s.want) == null) {
            std.debug.print("want {s} in: {s}\n", .{ s.want, row });
            return error.TestUnexpectedResult;
        }
        if (s.not) |n| try expect(std.mem.indexOf(u8, row, n) == null);
    }
}

test "a snapshot carries process, title_current and the active command's cmdline" {
    var c = try Client.init(80, 6);
    defer c.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    try c.app.shared.paneEntity((try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"pane\":\"p0\",\"session\":\"s0\",\"argv0\":\"sh\",\"process\":\"make\",\"title_current\":false}", .{})));
    const info = c.app.shared.pane("p0").?;
    try std.testing.expectEqualStrings("make", info.process.?);
    try expect(!info.title_current);
    try c.app.shared.commandEntity(try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"pane\":\"p0\",\"command\":\"p0/c3\",\"cmdline\":\"make -j8\"}", .{}));
    try std.testing.expectEqualStrings("make -j8", info.cmdline.?);
    // A later entity without them clears both; a non-boolean title_current is bad.
    try c.app.shared.paneEntity(try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"pane\":\"p0\",\"session\":\"s0\",\"title_current\":true}", .{}));
    try expect(info.process == null and info.title_current);
    try std.testing.expectError(error.BadEvent, c.app.shared.paneEntity(try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"pane\":\"p0\",\"session\":\"s0\",\"title_current\":1}", .{})));
}
