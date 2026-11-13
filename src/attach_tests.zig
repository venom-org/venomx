//! Attach client tests against the real pane stream server over in-memory
//! binary connections: wire encoding, handshake, incremental backfill,
//! pending rows, offset mismatch, per-stream resync, resume and topology.
const std = @import("std");
const proto = @import("proto");
const term = @import("venom-term");
const s = @import("stream.zig");
const Server = @import("server.zig").Server;
const pane_stream = @import("pane_stream");
const PaneStream = pane_stream.PaneStream;
const raw_filter = @import("raw_filter.zig");
const chrome_theme = @import("chrome_theme.zig");
const app_mod = @import("attach_app.zig");
const App = app_mod.App;
const a = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test {
    _ = @import("host_probe.zig");
    _ = @import("raw_filter.zig");
    _ = @import("attach_layout.zig");
    _ = @import("attach_border.zig");
    _ = @import("attach_chrome.zig");
    _ = @import("pane_text.zig");
    _ = @import("chrome_tests.zig");
    _ = @import("principal_events_tests.zig");
    _ = @import("keys_tests.zig");
    _ = @import("floats_tests.zig");
    _ = @import("status_line_tests.zig");
    _ = @import("status_tests.zig");
    _ = @import("attach_exec.zig");
    _ = @import("chrome_theme.zig");
    _ = @import("theme_tests.zig");
    _ = @import("fangs.zig");
    _ = @import("restore_notice.zig");
    _ = @import("denied_notice.zig");
    _ = @import("fuzzy.zig");
    _ = @import("copy_mode.zig");
}

fn reader(_: ?*anyopaque, _: *const proto.Connection, _: []const u8) s.Grants {
    return .{ .read = true };
}

fn writer(_: ?*anyopaque, _: *const proto.Connection, _: []const u8) s.Grants {
    return .{ .read = true, .write = true };
}

/// One client connection to the in-process server.
const Wire = struct {
    conn: proto.Connection,
    fn init(max_frame: u32) !Wire {
        var conn = proto.Connection.init(a, -1);
        conn.protocol = .binary;
        conn.ready = true;
        conn.max_frame = max_frame;
        try conn.caps.append(a, s.capability);
        return .{ .conn = conn };
    }
    fn deinit(self: *Wire, server: *Server) void {
        server.closed(&self.conn);
        self.conn.deinit();
    }
    fn send(self: *Wire, server: *Server, c: *PaneStream) !void {
        for (c.outbox.items) |o| {
            defer o.deinit(a);
            try server.message(&self.conn, .{ .frame = .{ .kind = o.kind, .stream = c.id, .payload = o.payload } });
        }
        c.outbox.clearRetainingCapacity();
    }
    /// One server pump; delivers its frames. Returns false when idle.
    fn step(self: *Wire, server: *Server, clients: []const *PaneStream) !bool {
        try server.pump(0);
        const out = self.conn.output.items;
        if (out.len == 0) return false;
        var at: usize = 0;
        while (at < out.len) {
            const kind = std.mem.readInt(u16, out[at..][0..2], .big);
            const id = std.mem.readInt(u32, out[at + 2 ..][0..4], .big);
            const len = std.mem.readInt(u32, out[at + 6 ..][0..4], .big);
            const payload = out[at + 10 ..][0..len];
            for (clients) |c| if (c.id == id) try c.handle(kind, payload);
            at += 10 + len;
        }
        self.conn.output.clearRetainingCapacity();
        self.conn.sent = 0;
        for (clients) |c| try self.send(server, c);
        return true;
    }
    fn settle(self: *Wire, server: *Server, clients: []const *PaneStream) !void {
        for (0..100000) |_| if (!try self.step(server, clients)) return;
        return error.NeverIdle;
    }
    fn until(self: *Wire, server: *Server, clients: []const *PaneStream, c: *const PaneStream, phase: pane_stream.Phase) !void {
        for (0..100000) |_| {
            if (c.phase == phase) return;
            if (!try self.step(server, clients)) break;
        }
        return error.NeverReached;
    }
};

fn screen(vt: anytype) ![]u8 {
    const r = vt.rows();
    return vt.exportRows(a, r.epoch, r.active, r.end);
}

test "snapshot paints at READY, history backfills incrementally with pending rows" {
    var server = Server.init(a, "venomx/test");
    defer server.deinit();
    // Wide, full rows span many ghostty pages, so backfill takes many chunks.
    const p = try server.createPane(.{ .cols = 250, .rows = 6 });
    var line: [300]u8 = undefined;
    const fill: [230]u8 = @splat('x');
    for (0..1200) |i| try p.feed(try std.fmt.bufPrint(&line, "history {d} {s}\r\n", .{ i, &fill }));
    try p.feed("prompt$ ");
    var w = try Wire.init(64 * 1024);
    defer w.deinit(&server);
    var c = try PaneStream.init(a, "p0", 1, .{ .cols = 250, .rows = 6 }, 100000);
    defer c.deinit();
    try c.attach(null);
    try w.send(&server, &c);
    try w.until(&server, &.{&c}, &c, .live);
    // Paint is possible before any history: the screen already matches.
    const expected = try screen(p.vt);
    defer a.free(expected);
    const painted = try screen(c.vt.?);
    defer a.free(painted);
    try std.testing.expectEqualStrings(expected, painted);
    const first = c.pendingRows().?;
    try expect(first.low == p.vt.rows().oldest and first.high > first.low);
    var partial = false;
    while (c.backfill == .pending) {
        if (!try w.step(&server, &.{&c})) break;
        if (c.pendingRows()) |now| if (now.high < first.high and now.high > now.low) {
            partial = true;
        };
    }
    try expectEqual(pane_stream.Backfill.done, c.backfill);
    try expect(partial);
    try expectEqual(@as(?@TypeOf(first), null), c.pendingRows());
    const sr = p.vt.rows();
    const cr = c.vt.?.rows();
    try expectEqual(sr.oldest, cr.oldest);
    const all_server = try p.vt.exportRows(a, sr.epoch, sr.oldest, sr.end);
    defer a.free(all_server);
    const all_client = try c.vt.?.exportRows(a, cr.epoch, cr.oldest, cr.end);
    defer a.free(all_client);
    try std.testing.expectEqualStrings(all_server, all_client);
}

test "typing reaches the PTY queue; offset mismatch resyncs only that stream" {
    var server = Server.init(a, "venomx/test");
    defer server.deinit();
    server.authorize = writer;
    const p0 = try server.createPane(.{ .cols = 40, .rows = 4 });
    const p1 = try server.createPane(.{ .cols = 40, .rows = 4 });
    try p0.feed("zero ");
    try p1.feed("one ");
    var w = try Wire.init(1 << 20);
    defer w.deinit(&server);
    var c1 = try PaneStream.init(a, "p0", 1, .{ .cols = 40, .rows = 4 }, 0);
    defer c1.deinit();
    var c3 = try PaneStream.init(a, "p1", 3, .{ .cols = 40, .rows = 4 }, 0);
    defer c3.deinit();
    const both = [_]*PaneStream{ &c1, &c3 };
    for (both) |c| {
        try c.attach(null);
        try w.send(&server, c);
    }
    try w.settle(&server, &both);
    try expect(c1.writer and c1.phase == .live and c3.phase == .live);
    try c1.input("ls\r");
    try w.send(&server, &c1);
    try std.testing.expectEqualStrings("ls\r", p0.input.items);
    // A PTY frame that does not start at the applied offset is a gap.
    var bogus: [12]u8 = undefined;
    std.mem.writeInt(u64, bogus[0..8], c1.offset + 7, .big);
    @memcpy(bogus[8..], "junk");
    try c1.handle(s.Kind.pty, &bogus);
    try expect(c1.discarding);
    try expectEqual(pane_stream.ResyncCause.gap, c1.last_resync.?);
    try p0.feed("dropped-or-snapshotted ");
    try w.send(&server, &c1);
    try w.settle(&server, &both);
    try expect(c1.phase == .live and !c1.discarding);
    try expectEqual(@as(u32, 2), c1.snap);
    try expectEqual(@as(u32, 1), c3.snap);
    try expectEqual(@as(u32, 0), c3.resyncs);
    try p0.feed("after");
    try p1.feed("still");
    try w.settle(&server, &both);
    const s1 = try screen(c1.vt.?);
    defer a.free(s1);
    try expect(std.mem.indexOf(u8, s1, "zero dropped-or-snapshotted after") != null);
    const s3 = try screen(c3.vt.?);
    defer a.free(s3);
    try expect(std.mem.indexOf(u8, s3, "one still") != null);
    // A RESIZE marker at the wrong offset also restores via snapshot.
    try c3.handle(s.Kind.resize, "{\"offset\":999999,\"cols\":20,\"rows\":4,\"epoch\":9,\"oldest\":0,\"active\":0}");
    try expectEqual(pane_stream.ResyncCause.resize_offset, c3.last_resync.?);
    try w.send(&server, &c3);
    try w.settle(&server, &both);
    try expectEqual(@as(u32, 2), c3.snap);
}

test "reconnect resumes at the applied offset; pane removal closes the stream" {
    var server = Server.init(a, "venomx/test");
    defer server.deinit();
    const p = try server.createPane(.{ .cols = 30, .rows = 3 });
    try p.feed("abc");
    var c = try PaneStream.init(a, "p0", 1, .{ .cols = 30, .rows = 3 }, 0);
    defer c.deinit();
    {
        var w = try Wire.init(1 << 20);
        defer w.deinit(&server);
        try c.attach(null);
        try w.send(&server, &c);
        try w.settle(&server, &.{&c});
    }
    try p.feed("def");
    var w2 = try Wire.init(1 << 20);
    defer w2.deinit(&server);
    try c.reattach(5);
    try w2.send(&server, &c);
    try w2.settle(&server, &.{&c});
    try expectEqual(@as(u32, 1), c.snap);
    const text = try screen(c.vt.?);
    defer a.free(text);
    try expect(std.mem.startsWith(u8, text, "abcdef"));
    server.removePane(p);
    try w2.settle(&server, &.{&c});
    try std.testing.expectEqualStrings("pane_removed", c.closed.?);
}

/// Feed one App's queued frames to the server and deliver replies to it.
fn exchange(server: *Server, w: *Wire, app: *App) !void {
    for (0..100000) |_| {
        for (app.panes.items) |pv| try w.send(server, &pv.stream);
        try server.pump(0);
        const out = w.conn.output.items;
        if (out.len == 0) return;
        var at: usize = 0;
        while (at < out.len) {
            const kind = std.mem.readInt(u16, out[at..][0..2], .big);
            const id = std.mem.readInt(u32, out[at + 2 ..][0..4], .big);
            const len = std.mem.readInt(u32, out[at + 6 ..][0..4], .big);
            try app.frame(id, kind, out[at + 10 ..][0..len]);
            at += 10 + len;
        }
        w.conn.output.clearRetainingCapacity();
        w.conn.sent = 0;
    }
    return error.NeverIdle;
}
fn render(app: *App) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var surface = try term.Surface.init(a, app.cols, app.rows);
    defer surface.deinit(&out.writer);
    try app.render(&surface);
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(a);
    for (0..app.rows) |y| {
        for (0..app.cols) |x| try text.appendSlice(a, surface.get(@intCast(x), @intCast(y)).?.text);
        try text.append(a, '\n');
    }
    return text.toOwnedSlice(a);
}

test "two clients scroll and select independently; typing reaches the shared pane" {
    var server = Server.init(a, "venomx/test");
    defer server.deinit();
    server.authorize = writer;
    const p = try server.createPane(.{ .cols = 40, .rows = 5 });
    var line: [32]u8 = undefined;
    for (0..50) |i| try p.feed(try std.fmt.bufPrint(&line, "row {d}\r\n", .{i}));
    var wa = try Wire.init(1 << 20);
    defer wa.deinit(&server);
    var wb = try Wire.init(1 << 20);
    defer wb.deinit(&server);
    var one = try App.init(a, .{ .pane = "p0" }, .{ .cols = 40, .rows = 6 }, .{});
    defer one.deinit();
    var two = try App.init(a, .{ .pane = "p0" }, .{ .cols = 40, .rows = 6 }, .{});
    defer two.deinit();
    try one.resize(40, 6);
    try two.resize(40, 6);
    try exchange(&server, &wa, &one);
    try exchange(&server, &wb, &two);
    try one.run(.{ .local = .scroll_page_up });
    try one.run(.{ .local = .scroll_page_up });
    try expect(one.panes.items[0].scroll != null);
    try expect(two.panes.items[0].scroll == null);
    const a_text = try render(&one);
    defer a.free(a_text);
    const b_text = try render(&two);
    defer a.free(b_text);
    try expect(std.mem.indexOf(u8, a_text, "row 41") != null);
    try expect(std.mem.indexOf(u8, b_text, "row 41") == null);
    try expect(std.mem.indexOf(u8, b_text, "row 49") != null);
    // Typing in one client goes to the pane and returns that client to live.
    _ = try one.feedInput("echo hi\r");
    try expect(one.panes.items[0].scroll == null);
    try exchange(&server, &wa, &one);
    try std.testing.expectEqualStrings("echo hi\r", p.input.items);
    try p.feed("hi\r\n");
    try exchange(&server, &wa, &one);
    try exchange(&server, &wb, &two);
    for ([_]*App{ &one, &two }) |client| {
        const t = try render(client);
        defer a.free(t);
        try expect(std.mem.indexOf(u8, t, "hi") != null);
    }
    // Mouse selection stays local and copies through OSC 52. Row 1 is the
    // status line, so the pane starts on host row 2.
    _ = try two.feedInput("\x1b[<0;1;2M\x1b[<32;5;2M\x1b[<0;5;2m");
    try expect(two.panes.items[0].selection != null);
    try expect(one.panes.items[0].selection == null);
    try expect(std.mem.startsWith(u8, two.host.items, "\x1b]52;c;"));
    // The leader binding detaches with CLOSE on every stream.
    _ = try one.feedInput("\x02d");
    try std.testing.expectEqualStrings("detached", one.quit.?);
    try expectEqual(@as(u16, proto.Kind.close), one.panes.items[0].stream.outbox.items[0].kind);
}

test "session topology from events: staging, splits, focus fallback, empty states" {
    var app = try App.init(a, .{ .session = "s0" }, .{ .cols = 81, .rows = 25 }, .{});
    defer app.deinit();
    try app.control("{\"id\":2,\"item\":{\"type\":\"state.snapshot\",\"data\":{\"entities\":[{\"resource\":\"window:w1\",\"entity_type\":\"window\",\"content\":\"{\\\"window\\\":\\\"w1\\\",\\\"session\\\":\\\"s0\\\",\\\"name\\\":\\\"\\\",\\\"revision\\\":1,\\\"nodes\\\":[{\\\"kind\\\":\\\"pane\\\",\\\"pane\\\":\\\"p1\\\"}]}\",\"event_types\":[]},{\"resource\":\"window:w9\",\"entity_type\":\"window\",\"content\":\"{\\\"window\\\":\\\"w9\\\",\\\"session\\\":\\\"s1\\\",\\\"name\\\":\\\"\\\",\\\"revision\\\":1,\\\"nodes\\\":[]}\",\"event_types\":[]}]}}}");
    // Staged until the checkpoint: nothing is attached yet.
    try expectEqual(@as(usize, 0), app.panes.items.len);
    try app.control("{\"id\":2,\"item\":{\"type\":\"stream.checkpoint\",\"data\":{}}}");
    try app.control("{\"id\":2,\"item\":{\"type\":\"window.created\",\"data\":{\"window\":\"w0\",\"session\":\"s0\",\"name\":\"\",\"revision\":1,\"nodes\":[{\"kind\":\"pane\",\"pane\":\"p0\"}]}}}");
    // The lowest-ID window is shown first; other sessions are filtered out.
    try expectEqual(@as(usize, 2), app.windows.items.len);
    try std.testing.expectEqualStrings("w1", app.active.?);
    try app.run(.{ .local = .window_prev });
    try std.testing.expectEqualStrings("w0", app.active.?);
    try std.testing.expectEqualStrings("p0", app.focus.?);
    try app.control("{\"id\":2,\"item\":{\"type\":\"window.layout_changed\",\"data\":{\"window\":\"w0\",\"session\":\"s0\",\"revision\":2,\"nodes\":[{\"kind\":\"split\",\"axis\":\"cols\",\"first\":1,\"second\":2},{\"kind\":\"pane\",\"pane\":\"p0\"},{\"kind\":\"pane\",\"pane\":\"p2\"}]}}}");
    // Detached p1's CLOSE is queued; p0 and p2 are attached with half widths.
    try expect(app.pane("p2") != null);
    try expectEqual(@as(u16, 40), app.pane("p0").?.rect.width);
    try expectEqual(@as(u16, 40), app.pane("p2").?.rect.width);
    try app.run(.{ .local = .focus_next });
    try std.testing.expectEqualStrings("p2", app.focus.?);
    // A stale revision never rolls the topology back.
    try app.control("{\"id\":2,\"item\":{\"type\":\"window.layout_changed\",\"data\":{\"window\":\"w0\",\"session\":\"s0\",\"revision\":1,\"nodes\":[{\"kind\":\"pane\",\"pane\":\"p0\"}]}}}");
    try expect(app.pane("p2") != null);
    try app.control("{\"id\":2,\"item\":{\"type\":\"window.layout_changed\",\"data\":{\"window\":\"w0\",\"session\":\"s0\",\"revision\":3,\"nodes\":[{\"kind\":\"pane\",\"pane\":\"p0\"}]}}}");
    try std.testing.expectEqualStrings("p0", app.focus.?);
    // Splitting is a schema verb sent with the client's own identity.
    try app.run(.{ .verb = .split_right });
    try std.testing.expectEqualStrings("pane.split", app.requests.items[0].verb);
    try expect(std.mem.indexOf(u8, app.requests.items[0].params, "\"axis\":\"cols\"") != null);
    // The built-in split binding asks for on_exit removal.
    try expect(std.mem.indexOf(u8, app.requests.items[0].params, "\"on_exit\":\"remove\"") != null);
    try app.control("{\"id\":10,\"error\":{\"code\":\"denied.spawn\",\"message\":\"x\"}}");
    try expect(std.mem.indexOf(u8, app.message.items, "denied.spawn") != null);
    try app.control("{\"id\":2,\"item\":{\"type\":\"window.layout_changed\",\"data\":{\"window\":\"w0\",\"session\":\"s0\",\"revision\":4,\"nodes\":[]}}}");
    const empty = try render(&app);
    defer a.free(empty);
    try expect(std.mem.indexOf(u8, empty, "window w0 is empty") != null);
    try app.control("{\"id\":2,\"item\":{\"type\":\"window.removed\",\"data\":{\"window\":\"w0\",\"session\":\"s0\"}}}");
    try app.control("{\"id\":2,\"item\":{\"type\":\"window.removed\",\"data\":{\"window\":\"w1\",\"session\":\"s0\"}}}");
    const none = try render(&app);
    defer a.free(none);
    try expect(std.mem.indexOf(u8, none, "has no windows") != null);
}

test "a split or new window from this client takes its focus, and only its focus" {
    var app = try App.init(a, .{ .session = "s0" }, .{ .cols = 81, .rows = 25 }, .{});
    defer app.deinit();
    var other = try App.init(a, .{ .session = "s0" }, .{ .cols = 81, .rows = 25 }, .{});
    defer other.deinit();
    try app.control("{\"id\":2,\"item\":{\"type\":\"stream.checkpoint\",\"data\":{}}}");
    try app.control("{\"id\":2,\"item\":{\"type\":\"window.created\",\"data\":{\"window\":\"w0\",\"session\":\"s0\",\"name\":\"\",\"revision\":1,\"nodes\":[{\"kind\":\"pane\",\"pane\":\"p0\"}]}}}");
    try other.control("{\"id\":2,\"item\":{\"type\":\"stream.checkpoint\",\"data\":{}}}");
    try other.control("{\"id\":2,\"item\":{\"type\":\"window.created\",\"data\":{\"window\":\"w0\",\"session\":\"s0\",\"name\":\"\",\"revision\":1,\"nodes\":[{\"kind\":\"pane\",\"pane\":\"p0\"}]}}}");
    try std.testing.expectEqualStrings("p0", app.focus.?);
    // The reply comes first: focus waits for the topology to show the pane.
    try app.run(.{ .verb = .split_right });
    const split = app.pending.items[app.pending.items.len - 1].id;
    {
        const line = try std.fmt.allocPrint(a, "{{\"id\":{d},\"ok\":{{\"pane\":\"p1\",\"window\":\"w0\",\"session\":\"s0\"}}}}", .{split});
        defer a.free(line);
        try app.control(line);
    }
    try std.testing.expectEqualStrings("p0", app.focus.?);
    try app.control("{\"id\":2,\"item\":{\"type\":\"window.layout_changed\",\"data\":{\"window\":\"w0\",\"session\":\"s0\",\"name\":\"\",\"revision\":2,\"nodes\":[{\"kind\":\"split\",\"axis\":\"cols\",\"first\":1,\"second\":2},{\"kind\":\"pane\",\"pane\":\"p0\"},{\"kind\":\"pane\",\"pane\":\"p1\"}]}}}");
    try other.control("{\"id\":2,\"item\":{\"type\":\"window.layout_changed\",\"data\":{\"window\":\"w0\",\"session\":\"s0\",\"name\":\"\",\"revision\":2,\"nodes\":[{\"kind\":\"split\",\"axis\":\"cols\",\"first\":1,\"second\":2},{\"kind\":\"pane\",\"pane\":\"p0\"},{\"kind\":\"pane\",\"pane\":\"p1\"}]}}}");
    try std.testing.expectEqualStrings("p1", app.focus.?);
    try expect(app.want_focus == null);
    // Focus is client-local: the other client stays where it was.
    try std.testing.expectEqualStrings("p0", other.focus.?);
    // The event comes first, and a zoom that would hide the new pane ends.
    try app.run(.{ .local = .focus_prev });
    try app.run(.{ .local = .zoom });
    try std.testing.expectEqualStrings("p0", app.zoom.?);
    try app.run(.{ .verb = .split_down });
    const down = app.pending.items[app.pending.items.len - 1].id;
    try app.control("{\"id\":2,\"item\":{\"type\":\"window.layout_changed\",\"data\":{\"window\":\"w0\",\"session\":\"s0\",\"name\":\"\",\"revision\":3,\"nodes\":[{\"kind\":\"split\",\"axis\":\"cols\",\"first\":1,\"second\":4},{\"kind\":\"split\",\"axis\":\"rows\",\"first\":2,\"second\":3},{\"kind\":\"pane\",\"pane\":\"p0\"},{\"kind\":\"pane\",\"pane\":\"p2\"},{\"kind\":\"pane\",\"pane\":\"p1\"}]}}}");
    try std.testing.expectEqualStrings("p0", app.focus.?);
    {
        const line = try std.fmt.allocPrint(a, "{{\"id\":{d},\"ok\":{{\"pane\":\"p2\",\"window\":\"w0\",\"session\":\"s0\"}}}}", .{down});
        defer a.free(line);
        try app.control(line);
    }
    try std.testing.expectEqualStrings("p2", app.focus.?);
    try expect(app.zoom == null);
    // new-window: the client switches to the new window and focuses its pane.
    try app.run(.{ .verb = .new_window });
    const win = app.pending.items[app.pending.items.len - 1].id;
    try app.control("{\"id\":2,\"item\":{\"type\":\"window.created\",\"data\":{\"window\":\"w1\",\"session\":\"s0\",\"name\":\"\",\"revision\":1,\"nodes\":[{\"kind\":\"pane\",\"pane\":\"p3\"}]}}}");
    try std.testing.expectEqualStrings("w0", app.active.?);
    {
        const line = try std.fmt.allocPrint(a, "{{\"id\":{d},\"ok\":{{\"pane\":\"p3\",\"window\":\"w1\",\"session\":\"s0\"}}}}", .{win});
        defer a.free(line);
        try app.control(line);
    }
    try std.testing.expectEqualStrings("w1", app.active.?);
    try std.testing.expectEqualStrings("p3", app.focus.?);
    try expect(app.pane("p3") != null);
    // A pane removed before its window shows it is forgotten.
    try app.run(.{ .verb = .split_right });
    const gone = app.pending.items[app.pending.items.len - 1].id;
    {
        const line = try std.fmt.allocPrint(a, "{{\"id\":{d},\"ok\":{{\"pane\":\"p4\",\"window\":\"w1\",\"session\":\"s0\"}}}}", .{gone});
        defer a.free(line);
        try app.control(line);
    }
    try expect(app.want_focus != null);
    try app.control("{\"id\":2,\"item\":{\"type\":\"pane.removed\",\"data\":{\"pane\":\"p4\",\"session\":\"s0\"}}}");
    try expect(app.want_focus == null);
    try std.testing.expectEqualStrings("p3", app.focus.?);
}

test "the attached session's removal ends the client; other sessions' do not" {
    var app = try App.init(a, .{ .session = "s0" }, .{ .cols = 80, .rows = 24 }, .{});
    defer app.deinit();
    try app.control("{\"id\":2,\"item\":{\"type\":\"stream.checkpoint\",\"data\":{}}}");
    try app.control("{\"id\":2,\"item\":{\"type\":\"session.removed\",\"data\":{\"session\":\"s1\",\"reason\":\"empty\"}}}");
    try expect(app.quit == null and !app.session_ended);
    try app.control("{\"id\":2,\"item\":{\"type\":\"session.removed\",\"data\":{\"session\":\"s0\",\"reason\":\"empty\"}}}");
    try expect(app.session_ended);
    try std.testing.expectEqualStrings("session ended", app.quit.?);
    // new-window asks for on_exit removal like split.
    var other = try App.init(a, .{ .session = "s0" }, .{ .cols = 80, .rows = 24 }, .{});
    defer other.deinit();
    try other.run(.{ .verb = .new_window });
    try std.testing.expectEqualStrings("window.create", other.requests.items[0].verb);
    try expect(std.mem.indexOf(u8, other.requests.items[0].params, "\"on_exit\":\"remove\"") != null);
}

test "restored archive status is drawn in the status line, never in pane cells" {
    var app = try App.init(a, .{ .session = "s0" }, .{ .cols = 81, .rows = 10 }, .{});
    defer app.deinit();
    try app.control("{\"id\":2,\"item\":{\"type\":\"state.snapshot\",\"data\":{\"entities\":[{\"resource\":\"window:w0\",\"entity_type\":\"window\",\"content\":\"{\\\"window\\\":\\\"w0\\\",\\\"session\\\":\\\"s0\\\",\\\"name\\\":\\\"\\\",\\\"revision\\\":1,\\\"nodes\\\":[{\\\"kind\\\":\\\"split\\\",\\\"axis\\\":\\\"cols\\\",\\\"first\\\":1,\\\"second\\\":2},{\\\"kind\\\":\\\"pane\\\",\\\"pane\\\":\\\"p0\\\"},{\\\"kind\\\":\\\"pane\\\",\\\"pane\\\":\\\"p1\\\"}]}\",\"event_types\":[]}," ++
        "{\"resource\":\"pane:p0\",\"entity_type\":\"pane\",\"content\":\"{\\\"pane\\\":\\\"p0\\\",\\\"session\\\":\\\"s0\\\",\\\"title\\\":\\\"\\\",\\\"exited\\\":true,\\\"recovery\\\":{\\\"checkpoint\\\":\\\"c01234567-89ab-4cde-8fab-0123456789ab\\\",\\\"previous_pane\\\":\\\"p4\\\",\\\"process_state\\\":\\\"interrupted\\\",\\\"text_state\\\":\\\"plain\\\",\\\"cut_rows\\\":2}}\",\"event_types\":[]}," ++
        "{\"resource\":\"pane:p1\",\"entity_type\":\"pane\",\"content\":\"{\\\"pane\\\":\\\"p1\\\",\\\"session\\\":\\\"s0\\\",\\\"title\\\":\\\"\\\",\\\"exited\\\":false}\",\"event_types\":[]}]}}}");
    try app.control("{\"id\":2,\"item\":{\"type\":\"stream.checkpoint\",\"data\":{}}}");
    try std.testing.expectEqualStrings("p0", app.focus.?);
    try expect(app.archive("p0") != null and app.archive("p1") == null);
    const shown = try render(&app);
    defer a.free(shown);
    // The status line is the top row by default.
    try expectEqual(@as(?u16, 0), app.statusRow());
    const first = std.mem.indexOfScalar(u8, shown, '\n').?;
    try expect(std.mem.indexOf(u8, shown[0..first], " p0   p1  │ archive: interrupted, text plain") != null);
    try expect(std.mem.indexOf(u8, shown[first..], "archive") == null);
    // A live pane has no marker.
    try app.run(.{ .local = .focus_next });
    const live = try render(&app);
    defer a.free(live);
    try expect(std.mem.indexOf(u8, live, "archive") == null);
    // Relaunch replaces the archive with a new pane and removes this one.
    try app.control("{\"id\":2,\"item\":{\"type\":\"pane.removed\",\"data\":{\"pane\":\"p0\"}}}");
    try expect(app.archive("p0") == null);
}

test "the empty state of a session with no panes draws the fangs; a populated one does not" {
    var app = try App.init(a, .{ .session = "s0" }, .{ .cols = 81, .rows = 25 }, .{});
    defer app.deinit();
    try app.control("{\"id\":2,\"item\":{\"type\":\"stream.checkpoint\",\"data\":{}}}");
    const none = try render(&app);
    defer a.free(none);
    try expect(std.mem.indexOf(u8, none, "has no windows") != null);
    try expect(std.mem.indexOf(u8, none, "venomx 0.0.0") != null);
    try expect(std.mem.indexOf(u8, none, "━━━━━━  ━━━━━━") != null and std.mem.indexOf(u8, none, "●") != null);
    try app.control("{\"id\":2,\"item\":{\"type\":\"window.created\",\"data\":{\"window\":\"w0\",\"session\":\"s0\",\"name\":\"\",\"revision\":1,\"nodes\":[{\"kind\":\"pane\",\"pane\":\"p0\"}]}}}");
    const full = try render(&app);
    defer a.free(full);
    try expect(std.mem.indexOf(u8, full, "━━━━━━  ━━━━━━") == null);
}

fn restoredSnapshot(comptime attention: bool) []const u8 {
    return "{\"id\":2,\"item\":{\"type\":\"state.snapshot\",\"data\":{\"entities\":[{\"resource\":\"window:w0\",\"entity_type\":\"window\",\"content\":\"{\\\"window\\\":\\\"w0\\\",\\\"session\\\":\\\"s0\\\",\\\"name\\\":\\\"\\\",\\\"revision\\\":1,\\\"nodes\\\":[{\\\"kind\\\":\\\"split\\\",\\\"axis\\\":\\\"cols\\\",\\\"first\\\":1,\\\"second\\\":2},{\\\"kind\\\":\\\"pane\\\",\\\"pane\\\":\\\"p0\\\"},{\\\"kind\\\":\\\"pane\\\",\\\"pane\\\":\\\"p1\\\"}]}\",\"event_types\":[]}," ++
        "{\"resource\":\"pane:p0\",\"entity_type\":\"pane\",\"content\":\"{\\\"pane\\\":\\\"p0\\\",\\\"session\\\":\\\"s0\\\",\\\"title\\\":\\\"\\\",\\\"exited\\\":true," ++ (if (attention) "\\\"attention\\\":{\\\"level\\\":\\\"warn\\\",\\\"reason\\\":\\\"x\\\"}," else "") ++ "\\\"recovery\\\":{\\\"checkpoint\\\":\\\"c01234567-89ab-4cde-8fab-0123456789ab\\\",\\\"previous_pane\\\":\\\"p4\\\",\\\"process_state\\\":\\\"interrupted\\\",\\\"text_state\\\":\\\"plain\\\",\\\"cut_rows\\\":0}}\",\"event_types\":[]}," ++
        "{\"resource\":\"pane:p1\",\"entity_type\":\"pane\",\"content\":\"{\\\"pane\\\":\\\"p1\\\",\\\"session\\\":\\\"s0\\\",\\\"title\\\":\\\"\\\",\\\"exited\\\":false}\",\"event_types\":[]}]}}}";
}

test "the first attach after a restore shows the notice for its TTL; nothing dropped means no dropped part" {
    var app = try App.init(a, .{ .session = "s0" }, .{ .cols = 100, .rows = 10 }, .{});
    defer app.deinit();
    app.fixed_now = 1000;
    try app.control(restoredSnapshot(false));
    try expect(app.shared.newest(1000) == null);
    try app.control("{\"id\":2,\"item\":{\"type\":\"stream.checkpoint\",\"data\":{}}}");
    const n = app.shared.newest(1000).?;
    try std.testing.expectEqualStrings("● restored 1 pane", n.text);
    try expect(std.mem.indexOf(u8, n.text, "dropped") == null);
    const shown = try render(&app);
    defer a.free(shown);
    try expect(std.mem.indexOf(u8, shown, "● restored 1 pane") != null);
    // It expires with its TTL, and a second checkpoint does not bring it back.
    try expect(app.shared.newest(1000 + 10_001) == null);
    try app.control("{\"id\":2,\"item\":{\"type\":\"stream.checkpoint\",\"data\":{}}}");
    try expect(app.shared.newest(1000 + 10_001) == null);
}

test "the restore notice counts only the attached session's restored panes" {
    // p0 is a restored pane of s0; p1 is a restored pane of s1.
    const base = restoredSnapshot(false);
    const p1_session = try std.mem.replaceOwned(u8, a, base, "\\\"pane\\\":\\\"p1\\\",\\\"session\\\":\\\"s0\\\"", "\\\"pane\\\":\\\"p1\\\",\\\"session\\\":\\\"s1\\\"");
    defer a.free(p1_session);
    const both = try std.mem.replaceOwned(u8, a, p1_session, "\\\"exited\\\":false", "\\\"exited\\\":true,\\\"recovery\\\":{\\\"checkpoint\\\":\\\"c01234567-89ab-4cde-8fab-0123456789ab\\\",\\\"previous_pane\\\":\\\"p5\\\",\\\"process_state\\\":\\\"exited\\\",\\\"text_state\\\":\\\"omitted\\\"}");
    defer a.free(both);
    // Both sessions restored: s0 reports its one pane, not two.
    var s0 = try App.init(a, .{ .session = "s0" }, .{ .cols = 100, .rows = 10 }, .{});
    defer s0.deinit();
    s0.fixed_now = 1000;
    try s0.control(both);
    try s0.control("{\"id\":2,\"item\":{\"type\":\"stream.checkpoint\",\"data\":{}}}");
    try std.testing.expectEqualStrings("● restored 1 pane", s0.shared.newest(1000).?.text);
    // Only the other session was restored: a new session shows no notice.
    const only_other = try std.mem.replaceOwned(u8, a, both, "\\\"pane\\\":\\\"p0\\\",\\\"session\\\":\\\"s0\\\"", "\\\"pane\\\":\\\"p0\\\",\\\"session\\\":\\\"s1\\\"");
    defer a.free(only_other);
    var s2 = try App.init(a, .{ .session = "s2" }, .{ .cols = 100, .rows = 10 }, .{});
    defer s2.deinit();
    s2.fixed_now = 1000;
    try s2.control(only_other);
    try s2.control("{\"id\":2,\"item\":{\"type\":\"stream.checkpoint\",\"data\":{}}}");
    try expect(s2.shared.newest(1000) == null);
}

test "an empty window in a session that has panes gets the plain message, no fangs" {
    var app = try App.init(a, .{ .session = "s0" }, .{ .cols = 81, .rows = 25 }, .{});
    defer app.deinit();
    try app.control("{\"id\":2,\"item\":{\"type\":\"stream.checkpoint\",\"data\":{}}}");
    try app.control("{\"id\":2,\"item\":{\"type\":\"window.created\",\"data\":{\"window\":\"w0\",\"session\":\"s0\",\"name\":\"\",\"revision\":1,\"nodes\":[{\"kind\":\"pane\",\"pane\":\"p0\"}]}}}");
    try app.control("{\"id\":2,\"item\":{\"type\":\"window.created\",\"data\":{\"window\":\"w1\",\"session\":\"s0\",\"name\":\"\",\"revision\":1,\"nodes\":[]}}}");
    try app.run(.{ .local = .window_next });
    try std.testing.expectEqualStrings("w1", app.active.?);
    const t = try render(&app);
    defer a.free(t);
    try expect(std.mem.indexOf(u8, t, "window w1 is empty") != null);
    try expect(std.mem.indexOf(u8, t, "━━━━━━  ━━━━━━") == null);
}

test "the restore notice names the restored panes that need the user" {
    var app = try App.init(a, .{ .session = "s0" }, .{ .cols = 100, .rows = 10 }, .{});
    defer app.deinit();
    app.fixed_now = 1000;
    try app.control(restoredSnapshot(true));
    try app.control("{\"id\":2,\"item\":{\"type\":\"stream.checkpoint\",\"data\":{}}}");
    try std.testing.expectEqualStrings("● restored 1 pane │ ▲ 1 needs you: p0", app.shared.newest(1000).?.text);
}

test "commands share one name table between bindings and the prompt" {
    for (@import("keys.zig").builtin_bindings) |b| {
        const c = b.target.local;
        try expect(std.meta.eql(app_mod.parseCommand(app_mod.commandName(c)).?, c));
    }
    try std.testing.expectEqualStrings("scroll-page-up", app_mod.commandName(.{ .local = .scroll_page_up }));
    try expect(app_mod.parseCommand("split-down").? == .verb);
    try expect(app_mod.parseCommand("rm -rf") == null);
    var app = try App.init(a, .{ .pane = "p0" }, .{ .cols = 20, .rows = 4 }, .{});
    defer app.deinit();
    _ = try app.feedInput("\x02:detach\r");
    try std.testing.expectEqualStrings("detached", app.quit.?);
}

test "raw replay, filtered live bytes, input, resume and size fallback" {
    var server = Server.init(a, "venomx/test");
    defer server.deinit();
    server.authorize = writer;
    const p = try server.createPane(.{ .cols = 40, .rows = 4 });
    try p.feed("before attach\r\n");
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var c = try PaneStream.init(a, "p0", 1, .{ .cols = 40, .rows = 4 }, 100);
    defer c.deinit();
    var host: raw_filter.Host = .{ .out = &out.writer };
    c.mode = .raw;
    c.formats = &.{.vt};
    c.passthrough = host.passthrough();
    {
        var w = try Wire.init(4096);
        defer w.deinit(&server);
        try c.attach(null);
        try w.send(&server, &c);
        try w.settle(&server, &.{&c});
        try expect(c.vt == null and c.phase == .live);
        try expect(std.mem.indexOf(u8, out.written(), "before attach") != null);
        // The replay baseline is a soft reset, never RIS, which
        // would wipe the colors the user set on the host.
        try expect(std.mem.indexOf(u8, out.written(), "\x1bc") == null);
        try expect(std.mem.startsWith(u8, out.written(), @import("raw_filter.zig").soft_reset));
        out.clearRetainingCapacity();
        try p.feed("plain λ\x1b[6n\x1b]52;c;?\x07\x1b[31mred\x1b[0m");
        try w.settle(&server, &.{&c});
        try std.testing.expectEqualStrings("plain λ\x1b[31mred\x1b[0m", out.written());
        try c.input("\x1b[200~paste\x1b[201~\x03");
        try w.send(&server, &c);
        try expect(std.mem.endsWith(u8, p.input.items, "\x1b[200~paste\x1b[201~\x03"));
        try p.feed("\x1b[6");
        try w.settle(&server, &.{&c});
    }
    out.clearRetainingCapacity();
    // The host and tokenizer both retain partial state across an offset
    // resume; a query split by a disconnect still must not reach the host.
    try p.feed("nresumed");
    var w = try Wire.init(4096);
    defer w.deinit(&server);
    try c.reattach(3);
    try w.send(&server, &c);
    try w.settle(&server, &.{&c});
    try std.testing.expectEqualStrings("resumed", out.written());
    // A watcher cannot resize the shared pane. Stop forwarding immediately,
    // request emulation, and replace the display only at the next READY.
    c.writer = false;
    out.clearRetainingCapacity();
    try c.viewport(.{ .cols = 20, .rows = 3 });
    try expect(c.discarding and c.mode == .emulate);
    try w.send(&server, &c);
    try p.feed("after mismatch");
    try w.settle(&server, &.{&c});
    try expect(c.vt != null and !c.discarding and c.phase == .live);
    try expectEqual(@as(usize, 0), out.written().len);
    const painted = try screen(c.vt.?);
    defer a.free(painted);
    try expect(std.mem.indexOf(u8, painted, "after mismatch") != null);
}

test "detach restores host modes and only what raw output changed" {
    const restore = raw_filter.restoreHost;
    const modes = raw_filter.restore_modes;
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    // Emulating: pop the keyboard flags pushed on the alternate screen,
    // turn modes off, leave the alternate screen. No color writes at all.
    try restore(&out.writer, true, null);
    try std.testing.expectEqualStrings("\x1b[<u" ++ modes ++ "\x1b[?1049l", out.written());
    try expect(std.mem.indexOf(u8, out.written(), "\x1b]") == null);

    // Raw passthrough: nothing changed means no alternate screen exit (no
    // stray DECRC on the primary screen) and no color resets.
    const raw_tail = "\x1b[!p\x1b[?7h\x1b[?1l\x1b>\x1b(B\x0f\x1b[=0u";
    var f: raw_filter.Filter = .{};
    out.clearRetainingCapacity();
    try restore(&out.writer, false, &f);
    try std.testing.expectEqualStrings(modes ++ raw_tail, out.written());

    // Raw passthrough after a full-screen program set the background and
    // the palette and is still on its alternate screen.
    var sink: std.Io.Writer.Allocating = .init(a);
    defer sink.deinit();
    try f.feed(&sink.writer, "\x1b[?1049h\x1b]11;rgb:00/00/00\x07\x1b]4;3;#ffff00\x07\x1b=\x1b[?1h\x1b(0");
    out.clearRetainingCapacity();
    try restore(&out.writer, false, &f);
    try std.testing.expectEqualStrings(modes ++ "\x1b[?1049l\x1b]104;3\x1b\\\x1b]111\x1b\\" ++ raw_tail, out.written());

    // Raw that fell back to emulation: one alternate screen exit only.
    try f.feed(&sink.writer, "\x1b[?1049h\x1b]10;#ffffff\x07");
    out.clearRetainingCapacity();
    try restore(&out.writer, true, &f);
    try std.testing.expectEqualStrings("\x1b[<u" ++ modes ++ "\x1b[?1049l\x1b]110\x1b\\" ++ raw_tail, out.written());
}

/// A terminal with a theme: it answers color queries and applies color changes.
const FakeHost = struct {
    const default_bg = "rgb:00/00/00";
    bg: []const u8,
    replies: std.ArrayList(u8) = .empty,
    set: [64]u8 = undefined,
    fn deinit(self: *FakeHost) void {
        self.replies.deinit(a);
    }
    /// Takes the OSC 11 family and DA1 out of `bytes`; a real terminal handles
    /// them in the order written, and so does this.
    fn write(self: *FakeHost, bytes: []const u8) !void {
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, bytes, i, 0x1b)) |esc| {
            i = esc + 1;
            const rest = bytes[i..];
            if (std.mem.startsWith(u8, rest, "[c")) {
                try self.replies.appendSlice(a, "\x1b[?62;22c");
            } else if (std.mem.startsWith(u8, rest, "]111")) {
                self.bg = default_bg;
            } else if (std.mem.startsWith(u8, rest, "]11;")) {
                const end = std.mem.indexOfAny(u8, rest, "\x07\x1b") orelse continue;
                const value = rest[4..end];
                if (std.mem.eql(u8, value, "?")) {
                    try self.replies.print(a, "\x1b]11;{s}\x1b\\", .{self.bg});
                } else {
                    @memcpy(self.set[0..value.len], value);
                    self.bg = self.set[0..value.len];
                }
            }
        }
    }
};

test "a pane that changes OSC 11 leaves the host theme's color after detach" {
    const host_probe = @import("host_probe.zig");
    const theme = "rgb:12/34/56";
    var host: FakeHost = .{ .bg = theme };
    defer host.deinit();
    var probe: host_probe.Probe = .{};
    var f: raw_filter.Filter = .{ .snapshot = &probe.snapshot };
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();

    // Attach writes the queries, and the pane's output follows at once.
    try host.write(host_probe.queries);
    probe.start(0);
    try f.feed(&out.writer, "\x1b]11;#ffffff\x07");
    try host.write(out.written());
    try std.testing.expectEqualStrings("#ffffff", host.bg);
    out.clearRetainingCapacity();

    // The replies, read later, still give the color from before the change,
    // and a key typed around them is all the pane gets.
    var typed: [256]u8 = undefined;
    var n = probe.feed("a", &typed, 1);
    n += probe.feed(host.replies.items, typed[n..], 1);
    n += probe.feed("b", typed[n..], 1);
    try std.testing.expectEqualStrings("ab", typed[0..n]);
    try expect(probe.done);

    try raw_filter.restoreHost(&out.writer, false, &f);
    try host.write(out.written());
    try std.testing.expectEqualStrings(theme, host.bg);
}

test "a host that doesn't answer falls back to the terminal's default" {
    const host_probe = @import("host_probe.zig");
    var probe: host_probe.Probe = .{};
    probe.start(0);
    probe.giveUp();
    var f: raw_filter.Filter = .{ .snapshot = &probe.snapshot };
    var sink: std.Io.Writer.Allocating = .init(a);
    defer sink.deinit();
    try f.feed(&sink.writer, "\x1b]11;#ffffff\x07");
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try raw_filter.restoreHost(&out.writer, false, &f);
    try expect(std.mem.indexOf(u8, out.written(), "\x1b]111\x1b\\") != null);
}

test "restore turns off every mouse encoding and synchronized output" {
    const modes = raw_filter.restore_modes;
    for ([_][]const u8{ "\x1b[?1000l", "\x1b[?1002l", "\x1b[?1003l", "\x1b[?1005l", "\x1b[?1006l", "\x1b[?1015l", "\x1b[?1016l", "\x1b[?2026l" }) |mode| {
        try expect(std.mem.indexOf(u8, modes, mode) != null);
    }
    // Raw and presented exits both write them, ahead of the color restore.
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var f: raw_filter.Filter = .{};
    try raw_filter.restoreHost(&out.writer, false, &f);
    try expect(std.mem.startsWith(u8, out.written(), modes));
    out.clearRetainingCapacity();
    try raw_filter.restoreHost(&out.writer, true, &f);
    try expect(std.mem.startsWith(u8, out.written(), "\x1b[<u" ++ modes));
}

test "presented restore leaves one alternate screen, then restores the snapshot" {
    const host_probe = @import("host_probe.zig");
    var snap: host_probe.Snapshot = .{};
    snap.dynamic[1] = host_probe.Spec.parse("rgb:12/34/56").?;
    var f: raw_filter.Filter = .{ .snapshot = &snap };
    var sink: std.Io.Writer.Allocating = .init(a);
    defer sink.deinit();
    try f.feed(&sink.writer, "\x1b[?1049h\x1b]11;#ffffff\x07");
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try raw_filter.restoreHost(&out.writer, true, &f);
    try std.testing.expectEqualStrings("\x1b[<u" ++ raw_filter.restore_modes ++ "\x1b[?1049l\x1b]11;rgb:12/34/56\x1b\\" ++
        "\x1b[!p\x1b[?7h\x1b[?1l\x1b>\x1b(B\x0f\x1b[=0u", out.written());
    try expectEqual(@import("raw_filter.zig").Touched{}, f.touched);
    // Emulating from the start: no raw filter, so nothing but modes.
    out.clearRetainingCapacity();
    try raw_filter.restoreHost(&out.writer, true, null);
    try std.testing.expectEqualStrings("\x1b[<u" ++ raw_filter.restore_modes ++ "\x1b[?1049l", out.written());
}

test "replay while touched is dirty undoes, then soft resets, then replays" {
    var server = Server.init(a, "venomx/test");
    defer server.deinit();
    server.authorize = writer;
    const p = try server.createPane(.{ .cols = 40, .rows = 4 });
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var c = try PaneStream.init(a, "p0", 1, .{ .cols = 40, .rows = 4 }, 100);
    defer c.deinit();
    var host: raw_filter.Host = .{ .out = &out.writer };
    c.mode = .raw;
    c.formats = &.{.vt};
    c.passthrough = host.passthrough();
    var snap: @import("host_probe.zig").Snapshot = .{};
    snap.dynamic[1] = @import("host_probe.zig").Spec.parse("rgb:12/34/56").?;
    host.filter.snapshot = &snap;
    var w = try Wire.init(4096);
    defer w.deinit(&server);
    try c.attach(null);
    try w.send(&server, &c);
    try w.settle(&server, &.{&c});
    try p.feed("\x1b]11;#ffffff\x07\x1b]10;#000000\x07\x1b[5 qMARK");
    try w.settle(&server, &.{&c});
    try expect(host.filter.touched.cursor_shape and host.filter.touched.dynamic != 0);
    out.clearRetainingCapacity();
    // A lost frame: the client asks again and gets a fresh snapshot.
    try c.requestResync(.gap);
    try w.send(&server, &c);
    try w.settle(&server, &.{&c});
    const replay = out.written();
    // Only what the pane changed: the replay leaves the palette and tab stops
    // alone, so there is nothing of them to undo.
    const undo_bytes = "\x1b]110\x1b\\\x1b]11;rgb:12/34/56\x1b\\\x1b[0 q";
    try std.testing.expectEqualStrings(undo_bytes ++ raw_filter.soft_reset, replay[0 .. undo_bytes.len + raw_filter.soft_reset.len]);
    try expect(std.mem.indexOf(u8, replay, "MARK") != null);
    try expect(std.mem.indexOf(u8, replay, "\x1bc") == null);
    // The pane's color came back with the replay, so detach still owes the
    // host its own.
    try expect(host.filter.touched.dynamic & 2 != 0);
    out.clearRetainingCapacity();
    try host.filter.undo(&out.writer);
    try expect(std.mem.indexOf(u8, out.written(), "\x1b]11;rgb:12/34/56\x1b\\") != null);
}

fn rawReplay(server: *Server, host: *raw_filter.Host, c: *PaneStream) !void {
    c.mode = .raw;
    c.formats = &.{.vt};
    c.passthrough = host.passthrough();
    var w = try Wire.init(4096);
    defer w.deinit(server);
    try c.attach(null);
    try w.send(server, c);
    try w.settle(server, &.{c});
}

test "raw attach to a pane that set no palette entry or tab stop leaves the host's" {
    var server = Server.init(a, "venomx/test");
    defer server.deinit();
    server.authorize = writer;
    const p = try server.createPane(.{ .cols = 40, .rows = 4 });
    try p.feed("\x1b[31mMARK\x1b[0m\r\nnext\tline");
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var c = try PaneStream.init(a, "p0", 1, .{ .cols = 40, .rows = 4 }, 100);
    defer c.deinit();
    var host: raw_filter.Host = .{ .out = &out.writer };
    try rawReplay(&server, &host, &c);
    const replay = out.written();
    try expect(c.phase == .live and std.mem.indexOf(u8, replay, "MARK") != null);
    for ([_][]const u8{ "\x1b]4;", "\x1b]104", "\x1b[3g", "\x1b[g", "\x1bH", "\x1b[?5W" }) |seq| {
        try expect(std.mem.indexOf(u8, replay, seq) == null);
    }
    // So detach owes the host nothing for them either.
    try expectEqual(@as(u256, 0), host.filter.touched.palette);
    try expect(!host.filter.touched.tabstops);
    out.clearRetainingCapacity();
    try host.filter.undo(&out.writer);
    try expectEqual(@as(usize, 0), out.written().len);
}

test "raw attach replays the palette entries and tab stops a program set, and detach undoes them" {
    var server = Server.init(a, "venomx/test");
    defer server.deinit();
    server.authorize = writer;
    const p = try server.createPane(.{ .cols = 40, .rows = 4 });
    try p.feed("\x1b]4;3;rgb:12/34/56\x07\x1b[3g\x1b[7G\x1bH\x1b[HMARK");
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var c = try PaneStream.init(a, "p0", 1, .{ .cols = 40, .rows = 4 }, 100);
    defer c.deinit();
    var host: raw_filter.Host = .{ .out = &out.writer };
    try rawReplay(&server, &host, &c);
    const replay = out.written();
    try expect(std.mem.indexOf(u8, replay, "MARK") != null);
    try expectEqual(@as(usize, 1), std.mem.count(u8, replay, "\x1b]4;"));
    try expect(std.mem.indexOf(u8, replay, "\x1b]4;3;rgb:12/34/56\x1b\\") != null);
    try expect(std.mem.indexOf(u8, replay, "\x1b[3g\x1b[7G\x1bH") != null);
    try expectEqual(@as(u256, 1) << 3, host.filter.touched.palette);
    try expect(host.filter.touched.tabstops);
    out.clearRetainingCapacity();
    try host.filter.undo(&out.writer);
    try std.testing.expectEqualStrings("\x1b]104;3\x1b\\\x1b[?5W", out.written());
}

test "initial raw size mismatch waits for READY then resyncs to emulation" {
    var server = Server.init(a, "venomx/test");
    defer server.deinit();
    _ = try server.createPane(.{ .cols = 40, .rows = 4 });
    var w = try Wire.init(4096);
    defer w.deinit(&server);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var c = try PaneStream.init(a, "p0", 1, .{ .cols = 20, .rows = 3 }, 0);
    defer c.deinit();
    var host: raw_filter.Host = .{ .out = &out.writer };
    c.mode = .raw;
    c.formats = &.{.vt};
    c.passthrough = host.passthrough();
    try c.attach(null);
    try w.send(&server, &c);
    try w.settle(&server, &.{&c});
    try expect(c.mode == .emulate and c.vt != null and c.phase == .live);
    try expectEqual(@as(usize, 0), out.written().len);
}

test "raw clipboard follows writer grants and live configuration changes" {
    var server = Server.init(a, "venomx/test");
    defer server.deinit();
    server.authorize = writer;
    const p = try server.createPane(.{ .cols = 40, .rows = 4 });
    var w = try Wire.init(4096);
    defer w.deinit(&server);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var c = try PaneStream.init(a, "p0", 1, .{ .cols = 40, .rows = 4 }, 0);
    defer c.deinit();
    var host: raw_filter.Host = .{ .out = &out.writer };
    c.mode = .raw;
    c.formats = &.{.vt};
    c.passthrough = host.passthrough();
    try c.attach(null);
    try w.send(&server, &c);
    try w.settle(&server, &.{&c});
    const copy = "\x1b]52;c;eA==\x07";
    out.clearRetainingCapacity();
    try p.feed(copy);
    try w.settle(&server, &.{&c});
    try std.testing.expectEqualStrings(copy, out.written());
    try p.reconfigure(.{ .raw_clipboard = .off });
    try w.settle(&server, &.{&c});
    out.clearRetainingCapacity();
    try p.feed(copy ++ "off");
    try w.settle(&server, &.{&c});
    try std.testing.expectEqualStrings("off", out.written());
    // Revoking write updates the client even while read remains granted.
    server.authorize = reader;
    try p.reconfigure(.{});
    try w.settle(&server, &.{&c});
    try expect(!c.writer and !c.clipboard);
    out.clearRetainingCapacity();
    try p.feed(copy ++ "watching");
    try w.settle(&server, &.{&c});
    try std.testing.expectEqualStrings("watching", out.written());
    try c.input("denied");
    try expectEqual(@as(usize, 0), c.outbox.items.len);
}

/// Assert the exact INPUT payloads before the transport consumes the queue.
fn expectInputs(p: *app_mod.PaneView, expected: []const u8) !usize {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(a);
    var frames: usize = 0;
    for (p.stream.outbox.items) |o| {
        try expectEqual(s.Kind.input, o.kind);
        try bytes.appendSlice(a, o.payload);
        frames += 1;
    }
    try std.testing.expectEqualStrings(expected, bytes.items);
    for (p.stream.outbox.items) |o| o.deinit(a);
    p.stream.outbox.clearRetainingCapacity();
    return frames;
}

test "attach encodes normalized keys using snapshot and live pane keyboard modes" {
    var server = Server.init(a, "venomx/test");
    defer server.deinit();
    server.authorize = writer;
    const p = try server.createPane(.{ .cols = 40, .rows = 5 });
    try p.feed("\x1b[?1h"); // vim's application cursor mode, before snapshot
    var w = try Wire.init(1 << 20);
    defer w.deinit(&server);
    var app = try App.init(a, .{ .pane = "p0" }, .{ .cols = 40, .rows = 6 }, .{});
    defer app.deinit();
    try app.resize(40, 6);
    try exchange(&server, &w, &app);
    const view = app.pane("p0").?;
    _ = try app.feedInput("\x1b[A");
    _ = try expectInputs(view, "\x1bOA");
    try p.feed("\x1b[?1l\x1b[>11u");
    try exchange(&server, &w, &app);
    _ = try app.feedInput("a\x1b[97;1:2u\x1b[97;1:3u");
    _ = try expectInputs(view, "\x1b[97u\x1b[97;1:2u\x1b[97;1:3u");
    // Local commands consume their releases; leader leader sends the leader.
    _ = try app.feedInput("\x1b[98;5u\x1b[98;5:3u\x1b[98;5u\x1b[98;5:3u");
    _ = try expectInputs(view, "\x1b[98;5u\x1b[98;5:3u");
    try p.feed("\x1b[<u");
    try exchange(&server, &w, &app);
    _ = try app.feedInput("\x1bOA"); // host's application mode -> pane legacy
    _ = try expectInputs(view, "\x1b[A");
    view.stream.writer = false;
    _ = try app.feedInput("denied\x1b[A");
    _ = try expectInputs(view, "");
}

fn readyInputApp() !App {
    var app = try App.init(a, .{ .pane = "p0" }, .{ .cols = 40, .rows = 6 }, .{});
    errdefer app.deinit();
    try app.resize(40, 6);
    const p = app.pane("p0").?;
    for (p.stream.outbox.items) |o| o.deinit(a);
    p.stream.outbox.clearRetainingCapacity();
    p.stream.vt = try @import("vt").Vt.init(a, .{ .cols = 40, .rows = 5 });
    p.stream.phase = .live;
    p.stream.writer = true;
    return app;
}

test "attach paste stays literal and uses the pane's bracketed-paste mode" {
    var app = try readyInputApp();
    defer app.deinit();
    const p = app.pane("p0").?;
    // Escape sequences, mouse reports, NUL, Ctrl-A d and invalid UTF-8 all
    // remain literal, even though the destination enables Kitty keyboard.
    try p.stream.vt.?.feed("\x1b[>11u");
    const literal = "one\r\n\x01d\x00\xff\x1b[A\x1b[<0;1;1M";
    _ = try app.feedInput("\x1b[200~" ++ literal ++ "\x1b[201~");
    try expectEqual(@as(usize, 1), try expectInputs(p, literal));
    try expect(app.quit == null);
    try p.stream.vt.?.feed("\x1b[?2004h");
    _ = try app.feedInput("\x1b[200~hello");
    _ = try expectInputs(p, ""); // short paste remains one atomic INPUT
    const incomplete = " world\x1b[20";
    const used = try app.feedInput(incomplete);
    try expectEqual(@as(usize, 6), used);
    try std.testing.expectEqualStrings("\x1b[20", incomplete[used..]);
    _ = try app.feedInput("\x1b[201~");
    try expectEqual(@as(usize, 1), try expectInputs(p, "\x1b[200~hello world\x1b[201~"));
    // Prompt paste cannot execute a local command or reach the pane.
    try app.run(.{ .local = .command_prompt });
    _ = try app.feedInput("\x1b[200~detach\r\x1b[201~");
    _ = try expectInputs(p, "");
    try expect(app.prompt != null and app.prompt.?.items.len == 0);
}

test "paste chunks respect max_frame and reconnect discards unfinished paste" {
    var app = try readyInputApp();
    defer app.deinit();
    const p = app.pane("p0").?;
    app.input_frame_limit = 16;
    try p.stream.vt.?.feed("\x1b[?2004h");
    const payload = "abcdefghijklmnopqrstuvwxyz0123456789";
    _ = try app.feedInput("\x1b[200~" ++ payload ++ "\x1b[201~");
    for (p.stream.outbox.items) |o| try expect(o.payload.len <= 16);
    try expectEqual(@as(usize, 3), try expectInputs(p, "\x1b[200~" ++ payload ++ "\x1b[201~"));
    _ = try app.feedInput("\x1b[200~unfinished");
    app.cancelPaste();
    _ = try app.feedInput("must be dropped\x01d\x1b[201~");
    _ = try expectInputs(p, "");
    try expect(app.quit == null);
    p.stream.writer = false;
    _ = try app.feedInput("\x1b[200~denied\x1b[201~");
    _ = try expectInputs(p, "");
}

test "mouse reports use pane-relative coordinates and Shift forces a local gesture" {
    var app = try readyInputApp();
    defer app.deinit();
    const p = app.pane("p0").?;
    p.rect = .{ .x = 10, .y = 2, .width = 30, .height = 3 };
    try p.stream.vt.?.feed("\x1b[?1002h\x1b[?1006h");
    _ = try app.feedInput("\x1b[<0;13;4M\x1b[<32;14;4M\x1b[<0;14;4m\x1b[<64;13;4M");
    _ = try expectInputs(p, "\x1b[<0;3;2M\x1b[<32;4;2M\x1b[<0;4;2m\x1b[<64;3;2M");
    try expect(p.selection == null and p.scroll == null);
    // Shift is only required at the start. Releasing Shift before dragging
    // cannot send the remainder of a local selection to the program.
    _ = try app.feedInput("\x1b[<4;11;3M\x1b[<32;15;3M\x1b[<0;15;3m");
    _ = try expectInputs(p, "");
    try expect(p.selection != null and !p.selection.?.dragging);
    // A drag outside the pane remains captured and clamps to its edge.
    _ = try app.feedInput("\x1b[<0;11;3M\x1b[<32;50;3M\x1b[<0;50;3m");
    _ = try expectInputs(p, "\x1b[<0;1;1M\x1b[<32;30;1M\x1b[<0;30;1m");
    try p.stream.vt.?.feed("\x1b[?1002l");
    _ = try app.feedInput("\x1b[<0;11;3M\x1b[<32;15;3M\x1b[<0;15;3m");
    _ = try expectInputs(p, "");
    try expect(p.selection != null);
}

test "paste delimiters and embedded escapes survive one-byte host reads" {
    var app = try readyInputApp();
    defer app.deinit();
    const p = app.pane("p0").?;
    try p.stream.vt.?.feed("\x1b[?2004h");
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(a);
    const bytes = "\x1b[200~x\x1b[20X\x01d\x1b[201~";
    for (bytes) |byte| {
        try pending.append(a, byte);
        const used = try app.feedInput(pending.items);
        std.mem.copyForwards(u8, pending.items[0 .. pending.items.len - used], pending.items[used..]);
        pending.items.len -= used;
    }
    try expectEqual(@as(usize, 0), pending.items.len);
    try expectEqual(@as(usize, 1), try expectInputs(p, bytes));
    try expect(app.quit == null);
    try expectEqual(@as(usize, 0), try app.feedInput("\x1b"));
    try app.flushEscape();
    _ = try expectInputs(p, "\x1b");
}

test "split panes keep keyboard modes separate and paste stays with its starting pane" {
    var app = try App.init(a, .{ .session = "s0" }, .{ .cols = 81, .rows = 6 }, .{});
    defer app.deinit();
    try app.control("{\"id\":2,\"item\":{\"type\":\"window.created\",\"data\":{\"window\":\"w0\",\"session\":\"s0\",\"revision\":1,\"nodes\":[{\"kind\":\"split\",\"axis\":\"cols\",\"first\":1,\"second\":2},{\"kind\":\"pane\",\"pane\":\"p0\"},{\"kind\":\"pane\",\"pane\":\"p1\"}]}}}");
    for (app.panes.items) |p| {
        for (p.stream.outbox.items) |o| o.deinit(a);
        p.stream.outbox.clearRetainingCapacity();
        p.stream.vt = try @import("vt").Vt.init(a, .{ .cols = 40, .rows = 5 });
        p.stream.phase = .live;
        p.stream.writer = true;
    }
    const left = app.pane("p0").?;
    const right = app.pane("p1").?;
    try right.stream.vt.?.feed("\x1b[?1h\x1b[?1000h\x1b[?1006h");
    _ = try app.feedInput("\x1b[A");
    _ = try expectInputs(left, "\x1b[A");
    _ = try expectInputs(right, "");
    _ = try app.feedInput("\x1b[200~start");
    try app.run(.{ .local = .focus_next });
    _ = try app.feedInput(" end\x1b[201~\x1b[A");
    _ = try expectInputs(left, "start end");
    _ = try expectInputs(right, "\x1bOA");
    // Border clicks do not reach either pane. A right-pane click uses its
    // own terminal modes and coordinates even while the left is focused.
    // Host row 1 is the status line and row 2 the title row,
    // so pane row 1 is host row 3.
    try app.run(.{ .local = .focus_prev });
    _ = try app.feedInput("\x1b[<0;41;2M\x1b[<0;43;3M\x1b[<0;43;3m");
    _ = try expectInputs(left, "");
    _ = try expectInputs(right, "\x1b[<0;2;1M\x1b[<0;2;1m");
    try std.testing.expectEqualStrings("p1", app.focus.?);
    right.stream.discarding = true;
    _ = try app.feedInput("\x1b[A\x1b[200~stale\x1b[201~");
    _ = try expectInputs(right, "");
}

test "attach forwards any-motion and pixel mouse reports with host cell geometry" {
    var app = try readyInputApp();
    defer app.deinit();
    const p = app.pane("p0").?;
    try p.stream.vt.?.feed("\x1b[?1003h\x1b[?1006h");
    // The pane starts below the top status line: host row 5 is pane row 4.
    _ = try app.feedInput("\x1b[<35;3;5M");
    _ = try expectInputs(p, "\x1b[<35;3;4M");
    try p.stream.vt.?.feed("\x1b[?1016h");
    app.mouse_geometry = .{ .cell_width = 8, .cell_height = 16 };
    _ = try app.feedInput("\x1b[<0;3;5M\x1b[<0;3;5m");
    _ = try expectInputs(p, "\x1b[<0;17;49M\x1b[<0;17;49m");
    app.mouse_geometry = .{};
    _ = try app.feedInput("\x1b[<0;3;5M\x1b[<0;3;5m");
    _ = try expectInputs(p, "");
    try expect(std.mem.indexOf(u8, app.message.items, "unavailable") != null);
}

test "Shift wheel scrolls locally while tracked wheel returns to live and respects the crop" {
    var app = try readyInputApp();
    defer app.deinit();
    const p = app.pane("p0").?;
    for (0..20) |_| try p.stream.vt.?.feed("history\r\n");
    try p.stream.vt.?.feed("\x1b[?1000h\x1b[?1006h");
    p.rect.height = 3; // a watcher/smaller client can crop the pane
    _ = try app.feedInput("\x1b[<68;1;2M");
    _ = try expectInputs(p, "");
    try expect(p.scroll != null);
    _ = try app.feedInput("\x1b[<64;1;2M");
    _ = try expectInputs(p, "\x1b[<64;1;3M");
    try expect(p.scroll == null);
}

test "shifted leader bindings work with Kitty report-all-keys and legacy input" {
    // The host sends what `CSI >31u` asks for: Ctrl and Shift as their own
    // key events, and `%` as `5` with Shift plus alternate and text.
    const leader = "\x1b[57442;5u\x1b[98;5u\x1b[98;5:3u\x1b[57442;5:3u";
    const cases = [_]struct { keys: []const u8 }{
        .{ .keys = leader ++ "\x1b[57441;2u\x1b[120:88;2;88u\x1b[120:88;2:3u\x1b[57441;2:3u" }, // X
        .{ .keys = "\x02X" },
    };
    for (cases) |case| {
        var app = try readyInputApp();
        defer app.deinit();
        _ = try app.feedInput(case.keys);
        try expectEqual(@as(usize, 1), app.requests.items.len);
        try std.testing.expectEqualStrings("pane.kill", app.requests.items[0].verb);
        _ = try expectInputs(app.pane("p0").?, "");
        try expect(!app.leaderPending());
    }
    // `:` opens the prompt; shifted letters reach its line.
    var app = try readyInputApp();
    defer app.deinit();
    _ = try app.feedInput(leader ++ "\x1b[57441;2u\x1b[59:58;2;58u\x1b[59:58;2:3u\x1b[57441;2:3u");
    try expect(app.prompt != null);
    _ = try app.feedInput("detach\x1b[57441;2u\x1b[57441;2:3u\r");
    try std.testing.expectEqualStrings("detached", app.quit.?);
    // Only the detach CLOSE is queued; no key reached the pane.
    for (app.pane("p0").?.stream.outbox.items) |o| try expect(o.kind != s.Kind.input);
    // Ctrl and Alt keys add nothing to the prompt line.
    var chords = try readyInputApp();
    defer chords.deinit();
    _ = try chords.feedInput(leader ++ ":");
    try expect(chords.prompt != null);
    _ = try chords.feedInput("\x1b[98;5u\x1b[97;3u\x1b[97;7u\x1b[98;5:3u");
    try expectEqual(@as(usize, 0), chords.prompt.?.items.len);
    _ = try chords.feedInput("a");
    try std.testing.expectEqualStrings("a", chords.prompt.?.items);
}

fn surfaceText(surface: *const term.Surface) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(a);
    for (0..surface.height) |y| {
        for (0..surface.width) |x| try text.appendSlice(a, surface.get(@intCast(x), @intCast(y)).?.text);
        try text.append(a, '\n');
    }
    return text.toOwnedSlice(a);
}

test "pane output alone rewrites only the rows it changed" {
    var server = Server.init(a, "venomx/test");
    defer server.deinit();
    server.authorize = writer;
    const p = try server.createPane(.{ .cols = 40, .rows = 5 });
    for (0..20) |i| {
        var line: [32]u8 = undefined;
        try p.feed(try std.fmt.bufPrint(&line, "row {d}\r\n", .{i}));
    }
    try p.feed("$ ");
    var w = try Wire.init(1 << 20);
    defer w.deinit(&server);
    var app = try App.init(a, .{ .pane = "p0" }, .{ .cols = 40, .rows = 6 }, .{});
    defer app.deinit();
    try app.resize(40, 6);
    try exchange(&server, &w, &app);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var surface = try term.Surface.init(a, app.cols, app.rows);
    defer surface.deinit(&out.writer);
    try app.render(&surface);
    try expect(!app.needsRender());
    // A typed key's echo: only pane cells changed.
    try p.feed("x");
    try exchange(&server, &w, &app);
    try expect(!app.dirty and app.pane_damage);
    surface.damage = null;
    try app.render(&surface);
    try expect(!app.needsRender());
    const pane_row = app.panes.items[0].rect.y + 4;
    try std.testing.expectEqual(term.Region{ .x = 2, .y = pane_row, .width = 1, .height = 1 }, surface.damage.?);
    try std.testing.expectEqual(term.Surface.Cursor{ .x = 3, .y = pane_row }, surface.cursor.?);
    // The patched surface is what a full render draws.
    const patched = try surfaceText(&surface);
    defer a.free(patched);
    const full = try render(&app);
    defer a.free(full);
    try std.testing.expectEqualStrings(full, patched);
    // Output that scrolls moves every row; still the same as a full render.
    try p.feed("\r\nmore\r\n$ ");
    try exchange(&server, &w, &app);
    try app.render(&surface);
    const scrolled = try surfaceText(&surface);
    defer a.free(scrolled);
    const full_scrolled = try render(&app);
    defer a.free(full_scrolled);
    try std.testing.expectEqualStrings(full_scrolled, scrolled);
    // A local selection makes the pane unpatchable: a full render.
    app.panes.items[0].selection = .{ .epoch = app.panes.items[0].stream.vt.?.rows().epoch, .anchor = .{ .row = 0, .col = 0 }, .head = .{ .row = 0, .col = 0 } };
    try p.feed("y");
    try exchange(&server, &w, &app);
    try app.render(&surface);
    const selected = try surfaceText(&surface);
    defer a.free(selected);
    const full_selected = try render(&app);
    defer a.free(full_selected);
    try std.testing.expectEqualStrings(full_selected, selected);
}

/// A wide pane whose history spans many ghostty pages, so backfill takes many
/// chunks and stays unfinished at the first READY.
fn tallPane(server: *Server) !*s.Pane {
    const p = try server.createPane(.{ .cols = 250, .rows = 6 });
    // Each step of a drag reflows at once.
    p.config.resize_coalesce_ms = 0;
    var line: [300]u8 = undefined;
    const fill: [230]u8 = @splat('x');
    for (0..1200) |i| try p.feed(try std.fmt.bufPrint(&line, "history {d} {s}\r\n", .{ i, &fill }));
    return p;
}

fn expectAllRows(c: *const PaneStream, p: *s.Pane) !void {
    const sr = p.vt.rows();
    const cr = c.vt.?.rows();
    try expectEqual(sr.oldest, cr.oldest);
    const all_server = try p.vt.exportRows(a, sr.epoch, sr.oldest, sr.end);
    defer a.free(all_server);
    const all_client = try c.vt.?.exportRows(a, cr.epoch, cr.oldest, cr.end);
    defer a.free(all_client);
    try std.testing.expectEqualStrings(all_server, all_client);
}

test "a resume with backfill pending recovers history and leaves loading" {
    var server = Server.init(a, "venomx/test");
    defer server.deinit();
    const p = try tallPane(&server);
    var c = try PaneStream.init(a, "p0", 1, .{ .cols = 250, .rows = 6 }, 100000);
    defer c.deinit();
    {
        var w = try Wire.init(64 * 1024);
        defer w.deinit(&server);
        try c.attach(null);
        try w.send(&server, &c);
        try w.until(&server, &.{&c}, &c, .live);
        try expectEqual(pane_stream.Backfill.pending, c.backfill);
    }
    var w2 = try Wire.init(64 * 1024);
    defer w2.deinit(&server);
    try c.reattach(5);
    try w2.send(&server, &c);
    try w2.settle(&server, &.{&c});
    // The server sends no SCROLLBACK on a resume, so nothing is still loading.
    try expectEqual(@as(u32, 1), c.snap);
    try expect(c.backfill != .pending);
    try expect(c.pendingRows() == null);

    try c.recoverBackfill(1000);
    try expectEqual(@as(?i64, 1000 + pane_stream.backfill_settle_ms), c.recoveryDeadline());
    try c.recoverBackfill(1000 + pane_stream.backfill_settle_ms);
    try expectEqual(pane_stream.ResyncCause.backfill, c.last_resync.?);
    try w2.send(&server, &c);
    try w2.settle(&server, &.{&c});
    try expectEqual(pane_stream.Backfill.done, c.backfill);
    try expectAllRows(&c, p);
    try c.recoverBackfill(5000);
    try c.recoverBackfill(6000);
    try expectEqual(@as(u32, 1), c.resyncs);
    try expectEqual(@as(?i64, null), c.recoveryDeadline());
}

test "an aborted backfill recovers once per settled drag, not once per reflow" {
    var server = Server.init(a, "venomx/test");
    defer server.deinit();
    server.authorize = writer;
    const p = try tallPane(&server);
    var w = try Wire.init(64 * 1024);
    defer w.deinit(&server);
    var c = try PaneStream.init(a, "p0", 1, .{ .cols = 250, .rows = 6 }, 100000);
    defer c.deinit();
    try c.attach(null);
    try w.send(&server, &c);
    try w.until(&server, &.{&c}, &c, .live);
    // Every step reflows, 40 ms apart: the settle time never passes.
    var now: i64 = 1000;
    for ([_]u16{ 120, 130, 140, 150, 160, 170, 180, 190, 200 }) |cols| {
        const epoch = c.vt.?.rows().epoch;
        try c.viewport(.{ .cols = cols, .rows = 6 });
        try w.send(&server, &c);
        try w.settle(&server, &.{&c});
        try expect(c.vt.?.rows().epoch != epoch);
        try expectEqual(pane_stream.Backfill.aborted, c.backfill);
        try c.recoverBackfill(now);
        try w.send(&server, &c);
        now += 40;
    }
    try expectEqual(@as(u32, 0), c.resyncs);
    try expect(c.vt.?.rows().oldest == p.vt.rows().oldest);
    try expect(c.vt.?.rows().active < p.vt.rows().active);

    try c.recoverBackfill(now);
    try expectEqual(@as(u32, 0), c.resyncs);
    try c.recoverBackfill(now + pane_stream.backfill_settle_ms - 40 - 1);
    try expectEqual(@as(u32, 0), c.resyncs);
    try c.recoverBackfill(now + pane_stream.backfill_settle_ms - 40);
    try expectEqual(@as(u32, 1), c.resyncs);
    try expectEqual(pane_stream.ResyncCause.backfill, c.last_resync.?);
    try w.send(&server, &c);
    try w.settle(&server, &.{&c});
    try expectEqual(pane_stream.Backfill.done, c.backfill);
    try expectAllRows(&c, p);

    // A resize after backfill finished loses nothing and asks for nothing.
    try c.viewport(.{ .cols = 100, .rows = 6 });
    try w.send(&server, &c);
    try w.settle(&server, &.{&c});
    try expectEqual(pane_stream.Backfill.done, c.backfill);
    try c.recoverBackfill(now + 1000);
    try expectEqual(@as(?i64, null), c.recoveryDeadline());
    try expectEqual(@as(u32, 1), c.resyncs);
}

test "a local StaleRows recovers history, and the abort that follows changes nothing" {
    var server = Server.init(a, "venomx/test");
    defer server.deinit();
    const p = try tallPane(&server);
    var w = try Wire.init(64 * 1024);
    defer w.deinit(&server);
    var c = try PaneStream.init(a, "p0", 1, .{ .cols = 250, .rows = 6 }, 100000);
    defer c.deinit();
    try c.attach(null);
    try w.send(&server, &c);
    try w.until(&server, &.{&c}, &c, .live);
    // Only this emulator's epoch moves, so the server keeps sending chunks.
    try c.vt.?.feed("\x1b[3J");
    try w.settle(&server, &.{&c});
    try expectEqual(pane_stream.Backfill.aborted, c.backfill);
    try expectEqual(@as(u32, 0), c.resyncs);
    try c.recoverBackfill(0);
    try c.recoverBackfill(pane_stream.backfill_settle_ms);
    try w.send(&server, &c);
    try w.settle(&server, &.{&c});
    try expectEqual(pane_stream.Backfill.done, c.backfill);
    try expectEqual(@as(u32, 1), c.resyncs);
    try expectAllRows(&c, p);
}

test "a stream with no history to lose never asks for it again" {
    const Case = struct { history: u64, formats: []const pane_stream.Format, raw: bool = false, short: bool = false };
    const cases = [_]Case{
        .{ .history = 0, .formats = &.{ .ghostty, .vt } },
        .{ .history = 100000, .formats = &.{.vt} },
        .{ .history = 100000, .formats = &.{.vt}, .raw = true },
        .{ .history = 100000, .formats = &.{ .ghostty, .vt }, .short = true },
    };
    for (cases) |case| {
        var server = Server.init(a, "venomx/test");
        defer server.deinit();
        server.authorize = writer;
        const p = if (case.short) try server.createPane(.{ .cols = 250, .rows = 6 }) else try tallPane(&server);
        var out: std.Io.Writer.Allocating = .init(a);
        defer out.deinit();
        var c = try PaneStream.init(a, "p0", 1, .{ .cols = 250, .rows = 6 }, case.history);
        defer c.deinit();
        c.formats = case.formats;
        var host: raw_filter.Host = .{ .out = &out.writer };
        if (case.raw) {
            c.mode = .raw;
            c.passthrough = host.passthrough();
        }
        {
            var w = try Wire.init(64 * 1024);
            defer w.deinit(&server);
            try c.attach(null);
            try w.send(&server, &c);
            try w.until(&server, &.{&c}, &c, .live);
            // Left unfinished, then resumed: nothing was lost and nothing loads.
        }
        var w2 = try Wire.init(64 * 1024);
        defer w2.deinit(&server);
        try c.reattach(5);
        try w2.send(&server, &c);
        try w2.settle(&server, &.{&c});
        try expect(c.backfill != .pending);
        try p.feed("after\r\n");
        try w2.settle(&server, &.{&c});
        for (0..3) |i| try c.recoverBackfill(@as(i64, @intCast(i)) * 1000);
        try expectEqual(@as(?i64, null), c.recoveryDeadline());
        try expectEqual(@as(u32, 0), c.resyncs);
    }
}

test "a stream with no history kept is not resynced by an aborted backfill" {
    var server = Server.init(a, "venomx/test");
    defer server.deinit();
    server.authorize = writer;
    const p = try server.createPane(.{ .cols = 80, .rows = 6 });
    p.config.resize_coalesce_ms = 0;
    try p.feed("only a screen");
    var w = try Wire.init(64 * 1024);
    defer w.deinit(&server);
    var c = try PaneStream.init(a, "p0", 1, .{ .cols = 80, .rows = 6 }, 100000);
    defer c.deinit();
    try c.attach(null);
    try w.send(&server, &c);
    try w.until(&server, &.{&c}, &c, .live);
    try c.viewport(.{ .cols = 40, .rows = 6 });
    try w.send(&server, &c);
    try w.settle(&server, &.{&c});
    for (0..3) |i| try c.recoverBackfill(@as(i64, @intCast(i)) * 1000);
    try expectEqual(@as(u32, 0), c.resyncs);
}

test "recovering history does not take the pane's size from the active writer" {
    var server = Server.init(a, "venomx/test");
    defer server.deinit();
    server.authorize = writer;
    const p = try tallPane(&server);
    // No hold: a RESYNC that counted as activity would move the size at once.
    p.config.latest_hold_ms = 0;
    var w = try Wire.init(64 * 1024);
    defer w.deinit(&server);
    var c1 = try PaneStream.init(a, "p0", 1, .{ .cols = 250, .rows = 6 }, 100000);
    defer c1.deinit();
    var c3 = try PaneStream.init(a, "p0", 3, .{ .cols = 120, .rows = 6 }, 100000);
    defer c3.deinit();
    const both = [_]*PaneStream{ &c1, &c3 };
    try c1.attach(null);
    try w.send(&server, &c1);
    try w.until(&server, &both, &c1, .live);
    // A second writer takes the pane and reflows it under the first's backfill.
    try c3.attach(null);
    try w.send(&server, &c3);
    try w.settle(&server, &both);
    try expectEqual(pane_stream.Backfill.aborted, c1.backfill);
    try expectEqual(@as(u16, 120), p.vt.size().cols);
    const epoch = p.vt.rows().epoch;

    try c1.recoverBackfill(0);
    try c1.recoverBackfill(pane_stream.backfill_settle_ms);
    try expectEqual(@as(u32, 1), c1.resyncs);
    try w.send(&server, &c1);
    try w.settle(&server, &both);
    try expectEqual(@as(u16, 120), p.vt.size().cols);
    try expectEqual(epoch, p.vt.rows().epoch);
    try expectEqual(pane_stream.Backfill.done, c1.backfill);
    try expectEqual(pane_stream.Backfill.done, c3.backfill);
    try expectEqual(@as(u32, 0), c3.resyncs);
    try expectAllRows(&c1, p);
    try expectAllRows(&c3, p);
}

test "App wakes for the settle time and queues one RESYNC for the transport" {
    var app = try readyInputApp();
    defer app.deinit();
    const p = app.pane("p0").?;
    p.stream.history_wanted = true;
    p.stream.backfill = .aborted;
    app.fixed_now = 1000;
    try app.recoverBackfill();
    try expectEqual(@as(?i64, 1000 + pane_stream.backfill_settle_ms), app.nextWake());
    try expectEqual(@as(usize, 0), p.stream.outbox.items.len);
    app.fixed_now = 1000 + pane_stream.backfill_settle_ms;
    try app.recoverBackfill();
    try expectEqual(@as(usize, 1), p.stream.outbox.items.len);
    try expectEqual(s.Kind.resync, p.stream.outbox.items[0].kind);
    try expect(std.mem.indexOf(u8, p.stream.outbox.items[0].payload, "\"claim\":false") != null);
    // Waiting for the server's RESYNC: no wakeups and no second request.
    try expectEqual(@as(?i64, null), app.nextWake());
    app.fixed_now = 5000;
    try app.recoverBackfill();
    try expectEqual(@as(usize, 1), p.stream.outbox.items.len);
}

test "a RESYNC after a resume follows the server's snapshot numbers" {
    var server = Server.init(a, "venomx/test");
    defer server.deinit();
    const p = try server.createPane(.{ .cols = 30, .rows = 3 });
    try p.feed("abc");
    var c = try PaneStream.init(a, "p0", 1, .{ .cols = 30, .rows = 3 }, 0);
    defer c.deinit();
    {
        var w = try Wire.init(1 << 20);
        defer w.deinit(&server);
        try c.attach(null);
        try w.send(&server, &c);
        try w.settle(&server, &.{&c});
        // Ahead of what the next stream on the server will number.
        try c.requestResync(.gap);
        try w.send(&server, &c);
        try w.settle(&server, &.{&c});
        try expectEqual(@as(u32, 2), c.snap);
    }
    var w2 = try Wire.init(1 << 20);
    defer w2.deinit(&server);
    try c.reattach(5);
    try w2.send(&server, &c);
    try w2.settle(&server, &.{&c});
    try c.requestResync(.gap);
    try w2.send(&server, &c);
    try w2.settle(&server, &.{&c});
    try expect(c.closed == null);
    try expectEqual(pane_stream.Phase.live, c.phase);
    try expectEqual(@as(u32, 1), c.snap);
    try expectEqual(@as(u32, 2), c.resyncs);
    try p.feed("def");
    try w2.settle(&server, &.{&c});
    const text = try screen(c.vt.?);
    defer a.free(text);
    try expect(std.mem.startsWith(u8, text, "abcdef"));
}

test "recovery waits until the alternate screen is left, and keeps the history" {
    for ([_]bool{ false, true }) |reflow| {
        var server = Server.init(a, "venomx/test");
        defer server.deinit();
        server.authorize = writer;
        const p = try tallPane(&server);
        var w = try Wire.init(64 * 1024);
        defer w.deinit(&server);
        var c = try PaneStream.init(a, "p0", 1, .{ .cols = 250, .rows = 6 }, 100000);
        defer c.deinit();
        try c.attach(null);
        try w.send(&server, &c);
        try w.until(&server, &.{&c}, &c, .live);
        if (reflow) {
            // Lost first, then the program enters the alternate screen inside
            // the settle time.
            try c.viewport(.{ .cols = 120, .rows = 6 });
            try w.send(&server, &c);
            try w.settle(&server, &.{&c});
            try c.recoverBackfill(0);
            try expect(c.recoveryDeadline() != null);
        }
        // Without a reflow, entering it during backfill is what aborts.
        try p.feed("\x1b[?1049h");
        try w.settle(&server, &.{&c});
        try expectEqual(pane_stream.Backfill.aborted, c.backfill);
        const kept = c.vt.?.rows().oldest;
        for (0..3) |i| try c.recoverBackfill(@as(i64, @intCast(i)) * 1000);
        try expectEqual(@as(?i64, null), c.recoveryDeadline());
        try expectEqual(@as(u32, 0), c.resyncs);
        try expectEqual(kept, c.vt.?.rows().oldest);

        try p.feed("\x1b[?1049l");
        try w.settle(&server, &.{&c});
        try c.recoverBackfill(5000);
        try expectEqual(@as(?i64, 5000 + pane_stream.backfill_settle_ms), c.recoveryDeadline());
        try c.recoverBackfill(5000 + pane_stream.backfill_settle_ms);
        try expectEqual(@as(u32, 1), c.resyncs);
        try w.send(&server, &c);
        try w.settle(&server, &.{&c});
        try expectEqual(pane_stream.Backfill.done, c.backfill);
        try expectAllRows(&c, p);
    }
}

test "a fresh attach on the alternate screen recovers all retained rows once after it leaves" {
    var server = Server.init(a, "venomx/test");
    defer server.deinit();
    server.authorize = writer;
    const p = try tallPane(&server);
    // A full-screen program is running before the client attaches.
    try p.feed("\x1b[?1049h");
    var w = try Wire.init(64 * 1024);
    defer w.deinit(&server);
    var c = try PaneStream.init(a, "p0", 1, .{ .cols = 250, .rows = 6 }, 100000);
    defer c.deinit();
    try c.attach(null);
    try w.send(&server, &c);
    try w.until(&server, &.{&c}, &c, .live);
    try w.settle(&server, &.{&c});
    // Still on the alternate screen: nothing is requested.
    for (0..3) |i| try c.recoverBackfill(@as(i64, @intCast(i)) * 1000);
    try expectEqual(@as(?i64, null), c.recoveryDeadline());
    try expectEqual(@as(u32, 0), c.resyncs);

    try p.feed("\x1b[?1049l");
    try w.settle(&server, &.{&c});
    try c.recoverBackfill(5000);
    try expectEqual(@as(?i64, 5000 + pane_stream.backfill_settle_ms), c.recoveryDeadline());
    try c.recoverBackfill(5000 + pane_stream.backfill_settle_ms);
    try w.send(&server, &c);
    try w.settle(&server, &.{&c});
    try c.recoverBackfill(20000);
    try c.recoverBackfill(30000);
    try expectEqual(@as(u32, 1), c.resyncs);
    try expectEqual(pane_stream.Backfill.done, c.backfill);
    try expectAllRows(&c, p);
}

test "a recovery snapshot clears scroll and selection; another resync keeps them" {
    var server = Server.init(a, "venomx/test");
    defer server.deinit();
    server.authorize = writer;
    const p = try server.createPane(.{ .cols = 40, .rows = 5 });
    var line: [32]u8 = undefined;
    for (0..50) |i| try p.feed(try std.fmt.bufPrint(&line, "row {d}\r\n", .{i}));
    var w = try Wire.init(1 << 20);
    defer w.deinit(&server);
    var app = try App.init(a, .{ .pane = "p0" }, .{ .cols = 40, .rows = 6 }, .{});
    defer app.deinit();
    try app.resize(40, 6);
    try exchange(&server, &w, &app);
    const pv = app.panes.items[0];
    try app.run(.{ .local = .scroll_page_up });
    pv.selection = .{ .epoch = pv.stream.vt.?.rows().epoch, .anchor = .{ .row = 1, .col = 0 }, .head = .{ .row = 1, .col = 3 } };

    try pv.stream.requestResync(.gap);
    try exchange(&server, &w, &app);
    try expect(pv.scroll != null and pv.selection != null);

    pv.stream.backfill = .aborted;
    pv.stream.history_wanted = true;
    app.fixed_now = 1000;
    try app.recoverBackfill();
    app.fixed_now = 1000 + pane_stream.backfill_settle_ms;
    try app.recoverBackfill();
    try expect(pv.stream.recovering);
    // Still showing the old rows until READY replaces them.
    try expect(pv.scroll != null and pv.selection != null);
    try exchange(&server, &w, &app);
    try expect(!pv.stream.recovering);
    try expect(pv.scroll == null and pv.selection == null);
    try expectEqual(pane_stream.Backfill.done, pv.stream.backfill);
}

test "a failed request send leaves exactly the unsent requests queued" {
    var app = try App.init(a, .{ .pane = "p0" }, .{ .cols = 80, .rows = 24 }, .{});
    defer app.deinit();
    try app.requestConfig();
    try app.requestKeys();
    const queued = app.requests.items.len;
    try expect(queued >= 2);
    const first = app.requests.items[0].id;
    const second = app.requests.items[1].id;
    const Sink = struct {
        fail_at: usize,
        calls: usize = 0,
        lines: std.ArrayList([]u8) = .empty,
        fn send(self: *@This(), line: []const u8) anyerror!void {
            defer self.calls += 1;
            if (self.calls == self.fail_at) return error.BrokenPipe;
            try self.lines.append(a, try a.dupe(u8, line));
        }
        fn deinit(self: *@This()) void {
            for (self.lines.items) |l| a.free(l);
            self.lines.deinit(a);
        }
    };
    var sink: Sink = .{ .fail_at = 1 };
    defer sink.deinit();
    try std.testing.expectError(error.BrokenPipe, app.flushRequests(&sink, Sink.send));
    // The sent one is gone and freed; the failed one and the rest stay.
    try expectEqual(queued - 1, app.requests.items.len);
    try expectEqual(second, app.requests.items[0].id);
    sink.fail_at = std.math.maxInt(usize);
    try app.flushRequests(&sink, Sink.send);
    try expectEqual(@as(usize, 0), app.requests.items.len);
    try expectEqual(queued, sink.lines.items.len);
    for (sink.lines.items, 0..) |line, i| {
        const parsed = try std.json.parseFromSlice(std.json.Value, a, line, .{});
        defer parsed.deinit();
        try expectEqual(first + @as(i64, @intCast(i)), parsed.value.object.get("id").?.integer);
    }
}

test "a client whose RESYNC is never answered releases held input and can detach" {
    var app = try readyInputApp();
    defer app.deinit();
    const p = app.pane("p0").?;
    // The server never answers: the stream stays discarding.
    p.stream.discarding = true;
    app.fixed_now = 1000;
    app.tick();
    try expect(app.holdInput());
    try expectEqual(@as(?i64, 1000 + app_mod.hold_limit_ms), app.nextWake());
    app.fixed_now = 1000 + app_mod.hold_limit_ms - 1;
    app.tick();
    try expect(app.holdInput());
    app.fixed_now = 1000 + app_mod.hold_limit_ms;
    app.tick();
    try expect(!app.holdInput());
    try expectEqual(@as(?i64, null), app.nextWake());
    _ = try app.feedInput("x\x02d");
    try std.testing.expectEqualStrings("detached", app.quit.?);
    // The stale key never reached the pane; only the detach CLOSE is queued.
    for (p.stream.outbox.items) |o| try expect(o.kind != s.Kind.input);
}

test "a client whose daemon never sends stream.checkpoint releases held input and can detach" {
    var app = try App.init(a, .{ .session = "s0" }, .{ .cols = 40, .rows = 6 }, .{});
    defer app.deinit();
    app.fixed_now = 1000;
    app.tick();
    try expect(!app.topology_ready);
    try expect(app.holdInput());
    app.fixed_now = 1000 + app_mod.hold_limit_ms;
    app.tick();
    try expect(!app.holdInput());
    _ = try app.feedInput("\x02d");
    try std.testing.expectEqualStrings("detached", app.quit.?);
}

test "a new hold cause or focused pane gets a fresh hold_limit_ms" {
    var app = try readyInputApp();
    defer app.deinit();
    const p = app.pane("p0").?;
    p.stream.discarding = true;
    app.fixed_now = 1000;
    app.tick();
    app.fixed_now = 1000 + app_mod.hold_limit_ms;
    app.tick();
    try expect(!app.holdInput());
    // A different cause straight after the timed-out one holds again.
    p.stream.discarding = false;
    p.stream.phase = .snapshot;
    // Seen before the next tick: the new cause already holds.
    try expect(app.holdInput());
    app.tick();
    try expect(app.holdInput());
    app.fixed_now = app.fixed_now.? + app_mod.hold_limit_ms - 1;
    app.tick();
    try expect(app.holdInput());
    app.fixed_now = app.fixed_now.? + 1;
    app.tick();
    try expect(!app.holdInput());
}

test "resetHold re-arms a timed-out hold, as a reconnect does" {
    var app = try readyInputApp();
    defer app.deinit();
    const p = app.pane("p0").?;
    p.stream.discarding = true;
    app.fixed_now = 1000;
    app.tick();
    app.fixed_now = 1000 + app_mod.hold_limit_ms;
    app.tick();
    try expect(!app.holdInput());
    // The link dropped: reattach puts the pane back in attaching.
    try p.stream.reattach(1);
    app.resetHold();
    try expect(app.holdInput());
    app.tick();
    try expect(app.holdInput());
    app.fixed_now = app.fixed_now.? + app_mod.hold_limit_ms;
    app.tick();
    try expect(!app.holdInput());
}

const ready_json = "{\"snap\":0,\"epoch\":1,\"oldest\":0,\"top\":0,\"active\":0,\"cols\":40,\"rows\":5,\"offset\":0}";

test "a new hold cause gets a fresh hold_limit_ms after a long run of holds" {
    var app = try readyInputApp();
    defer app.deinit();
    const p = app.pane("p0").?;
    p.stream.discarding = true;
    app.fixed_now = 1000;
    app.tick();
    // The discarding hold has run well past 2 * hold_limit_ms.
    app.fixed_now = 1000 + 3 * app_mod.hold_limit_ms;
    app.tick();
    try expect(!app.holdInput());
    // RESYNC arrives: discarding turns into a snapshot, a cause not yet seen.
    p.stream.discarding = false;
    p.stream.phase = .snapshot;
    try expect(app.holdInput());
    app.tick();
    app.fixed_now = app.fixed_now.? + app_mod.hold_limit_ms - 1;
    app.tick();
    try expect(app.holdInput());
    app.fixed_now = app.fixed_now.? + 1;
    app.tick();
    try expect(!app.holdInput());
    // The same cause again with the same generation, past the cap: no restart.
    p.stream.phase = .live;
    p.stream.discarding = true;
    p.stream.phase = .snapshot;
    try expect(!app.holdInput());
}

test "a snapshot cleared and re-entered within one batch gets a fresh timer" {
    var app = try readyInputApp();
    defer app.deinit();
    const p = app.pane("p0").?;
    p.stream.phase = .snapshot;
    p.stream.snap = 0;
    app.fixed_now = 1000;
    app.tick();
    app.fixed_now = 1000 + app_mod.hold_limit_ms;
    app.tick();
    try expect(!app.holdInput());
    // READY then RESYNC with no tick between: same cause and pane.
    try app.frame(p.stream.id, pane_stream.Kind.ready, ready_json);
    try expectEqual(.live, p.stream.phase);
    try app.frame(p.stream.id, pane_stream.Kind.resync, "{\"snap\":2}");
    try expectEqual(.snapshot, p.stream.phase);
    try expect(app.holdInput());
    app.tick();
    app.fixed_now = app.fixed_now.? + app_mod.hold_limit_ms - 1;
    app.tick();
    try expect(app.holdInput());
    app.fixed_now = app.fixed_now.? + 1;
    app.tick();
    try expect(!app.holdInput());
}

test "a snapshot re-entered within one batch past 2 * hold_limit_ms still holds" {
    var app = try readyInputApp();
    defer app.deinit();
    const p = app.pane("p0").?;
    p.stream.phase = .snapshot;
    p.stream.snap = 0;
    app.fixed_now = 1000;
    app.tick();
    app.fixed_now = 1000 + 3 * app_mod.hold_limit_ms;
    app.tick();
    try expect(!app.holdInput());
    try app.frame(p.stream.id, pane_stream.Kind.ready, ready_json);
    try app.frame(p.stream.id, pane_stream.Kind.resync, "{\"snap\":2}");
    try expect(app.holdInput());
    app.tick();
    app.fixed_now = app.fixed_now.? + app_mod.hold_limit_ms;
    app.tick();
    try expect(!app.holdInput());
}

test "focus flips stay bounded past the cap" {
    var app = try twoPaneApp();
    defer app.deinit();
    for (app.panes.items) |pv| pv.stream.phase = .snapshot;
    var t: i64 = 1000;
    var held = true;
    for (0..200) |_| {
        t += 500;
        app.fixed_now = t;
        try app.run(.{ .local = .focus_next });
        app.tick();
        held = app.holdInput();
    }
    try expect(!held);
}

test "a new snapshot on a pane focused past the cap still holds" {
    var app = try twoPaneApp();
    defer app.deinit();
    for (app.panes.items) |pv| pv.stream.phase = .snapshot;
    app.fixed_now = 1000;
    app.tick();
    app.fixed_now = 1000 + 3 * app_mod.hold_limit_ms;
    app.tick();
    try expect(!app.holdInput());
    try app.run(.{ .local = .focus_next });
    app.tick();
    try expect(!app.holdInput());
    const p = app.pane("p1").?;
    try app.frame(p.stream.id, pane_stream.Kind.ready, ready_json);
    try app.frame(p.stream.id, pane_stream.Kind.resync, "{\"snap\":2}");
    try expectEqual(.snapshot, p.stream.phase);
    try expect(app.holdInput());
    app.tick();
    app.fixed_now = app.fixed_now.? + app_mod.hold_limit_ms;
    app.tick();
    try expect(!app.holdInput());
}

test "attaching after a topology hold past 2 * hold_limit_ms gets a fresh hold" {
    var app = try App.init(a, .{ .session = "s0" }, .{ .cols = 40, .rows = 6 }, .{});
    defer app.deinit();
    app.fixed_now = 1000;
    app.tick();
    app.fixed_now = 1000 + 3 * app_mod.hold_limit_ms;
    app.tick();
    try expect(!app.holdInput());
    // The topology arrives: focus moves from none to p0, which is attaching.
    try app.control("{\"id\":2,\"item\":{\"type\":\"window.created\",\"data\":{\"window\":\"w0\",\"session\":\"s0\",\"revision\":1,\"nodes\":[{\"kind\":\"pane\",\"pane\":\"p0\"}]}}}");
    app.topology_ready = true;
    try std.testing.expectEqualStrings("p0", app.focus.?);
    try expectEqual(.attaching, app.pane("p0").?.stream.phase);
    try expect(app.holdInput());
    app.tick();
    app.fixed_now = app.fixed_now.? + app_mod.hold_limit_ms - 1;
    app.tick();
    try expect(app.holdInput());
    app.fixed_now = app.fixed_now.? + 1;
    app.tick();
    try expect(!app.holdInput());
}

fn twoPaneApp() !App {
    var app = try App.init(a, .{ .session = "s0" }, .{ .cols = 81, .rows = 6 }, .{});
    errdefer app.deinit();
    try app.control("{\"id\":2,\"item\":{\"type\":\"window.created\",\"data\":{\"window\":\"w0\",\"session\":\"s0\",\"revision\":1,\"nodes\":[{\"kind\":\"split\",\"axis\":\"cols\",\"first\":1,\"second\":2},{\"kind\":\"pane\",\"pane\":\"p0\"},{\"kind\":\"pane\",\"pane\":\"p1\"}]}}}");
    for (app.panes.items) |p| {
        for (p.stream.outbox.items) |o| o.deinit(a);
        p.stream.outbox.clearRetainingCapacity();
        p.stream.vt = try @import("vt").Vt.init(a, .{ .cols = 40, .rows = 5 });
        p.stream.phase = .live;
        p.stream.writer = true;
    }
    return app;
}

test "moving focus to another pane in the same state gets a fresh hold_limit_ms" {
    var app = try twoPaneApp();
    defer app.deinit();
    app.pane("p0").?.stream.discarding = true;
    app.pane("p1").?.stream.discarding = true;
    app.fixed_now = 1000;
    app.tick();
    app.fixed_now = 1000 + app_mod.hold_limit_ms;
    app.tick();
    try expect(!app.holdInput());
    try app.run(.{ .local = .focus_next });
    try std.testing.expectEqualStrings("p1", app.focus.?);
    try expect(app.holdInput());
    app.tick();
    app.fixed_now = app.fixed_now.? + app_mod.hold_limit_ms;
    app.tick();
    try expect(!app.holdInput());
}

test "focus flips cannot keep the hold past twice hold_limit_ms" {
    var app = try twoPaneApp();
    defer app.deinit();
    app.pane("p0").?.stream.discarding = true;
    app.pane("p1").?.stream.discarding = true;
    app.fixed_now = 1000;
    app.tick();
    app.fixed_now = 1000 + app_mod.hold_limit_ms;
    app.tick();
    try app.run(.{ .local = .focus_next });
    app.tick();
    try expect(app.holdInput());
    app.fixed_now = 1000 + 2 * app_mod.hold_limit_ms;
    app.tick();
    try app.run(.{ .local = .focus_prev });
    app.tick();
    try expect(!app.holdInput());
}

test "a stale hold generation picked up at focus holds once, then flips cannot restart it" {
    var app = try twoPaneApp();
    defer app.deinit();
    for (app.panes.items) |p| {
        p.stream.phase = .snapshot;
        p.stream.snap = 0;
    }
    app.fixed_now = 1000;
    app.tick();
    try std.testing.expectEqualStrings("p0", app.focus.?);
    const p1 = app.pane("p1").?;
    const gen = p1.hold_gen;
    // A new snapshot arrives while p1 is unfocused, without a tick between frames.
    try app.frame(p1.stream.id, pane_stream.Kind.ready, ready_json);
    try expectEqual(.live, p1.stream.phase);
    try app.frame(p1.stream.id, pane_stream.Kind.resync, "{\"snap\":2}");
    try expectEqual(.snapshot, p1.stream.phase);
    try expect(p1.hold_gen != gen);
    try std.testing.expectEqualStrings("p0", app.focus.?);
    app.fixed_now = 1000 + 3 * app_mod.hold_limit_ms;
    app.tick();
    try expect(!app.holdInput());

    // Picking up the stale generation starts one fresh run, even past the cap.
    try app.run(.{ .local = .focus_next });
    try std.testing.expectEqualStrings("p1", app.focus.?);
    try expect(app.holdInput());
    app.tick();
    try expect(app.holdInput());
    app.fixed_now = app.fixed_now.? + app_mod.hold_limit_ms + 1;
    app.tick();
    try expect(!app.holdInput());

    // No new frames: repeated focus changes must eventually stop holding.
    for (0..200) |_| {
        app.fixed_now = app.fixed_now.? + 500;
        try app.run(.{ .local = .focus_prev });
        app.tick();
        app.fixed_now = app.fixed_now.? + 500;
        try app.run(.{ .local = .focus_next });
        app.tick();
    }
    try std.testing.expectEqualStrings("p1", app.focus.?);
    try expect(!app.holdInput());
}

test "reattachStreams re-arms a timed-out hold" {
    var app = try readyInputApp();
    defer app.deinit();
    app.pane("p0").?.stream.discarding = true;
    app.fixed_now = 1000;
    app.tick();
    app.fixed_now = 1000 + app_mod.hold_limit_ms;
    app.tick();
    try expect(!app.holdInput());
    try app.reattachStreams();
    try expect(app.holdInput());
    app.tick();
    app.fixed_now = app.fixed_now.? + app_mod.hold_limit_ms;
    app.tick();
    try expect(!app.holdInput());
}

test "a pane attached without colours of its own gets the daemon's theme for OSC 10/11/12" {
    const Case = struct { name: chrome_theme.Name, fg: []const u8, bg: []const u8, cursor: []const u8 };
    for ([_]Case{
        .{ .name = .trve, .fg = "f1f1/f1f1/f1f1", .bg = "0000/0000/0000", .cursor = "fcfc/3030/2e2e" },
        .{ .name = .bone, .fg = "2121/1212/1212", .bg = "f3f3/f2f2/f2f2", .cursor = "aeae/0202/0000" },
    }) |case| {
        var server = Server.init(a, "venomx/test");
        defer server.deinit();
        server.authorize = writer;
        server.host_colors = chrome_theme.hostColors(case.name);
        const p = try server.createPane(.{ .cols = 40, .rows = 4 });
        var w = try Wire.init(1 << 20);
        defer w.deinit(&server);
        var c = try PaneStream.init(a, "p0", 1, .{ .cols = 40, .rows = 4 }, 0);
        defer c.deinit();
        try c.attach(null);
        try w.send(&server, &c);
        try w.settle(&server, &.{&c});
        for ([_]struct { query: []const u8, answer: []const u8 }{
            .{ .query = "\x1b]10;?\x07", .answer = case.fg },
            .{ .query = "\x1b]11;?\x07", .answer = case.bg },
            .{ .query = "\x1b]12;?\x07", .answer = case.cursor },
        }) |q| {
            p.input.clearRetainingCapacity();
            try p.feed(q.query);
            try expect(std.mem.indexOf(u8, p.input.items, q.answer) != null);
        }
    }
}

test "colours a client sends win over the daemon's theme" {
    var server = Server.init(a, "venomx/test");
    defer server.deinit();
    server.authorize = writer;
    server.host_colors = chrome_theme.hostColors(.bone);
    const p = try server.createPane(.{ .cols = 40, .rows = 4 });
    var w = try Wire.init(1 << 20);
    defer w.deinit(&server);
    var c = try PaneStream.init(a, "p0", 1, .{ .cols = 40, .rows = 4 }, 0);
    defer c.deinit();
    try c.attach(null);
    // PaneStream sends no colours; splice one into the ATTACH payload.
    const o = c.outbox.items[0];
    a.free(o.payload);
    c.outbox.items[0].payload = try a.dupe(u8, "{\"pane\":\"p0\",\"mode\":\"emulate\",\"formats\":[\"vt\"],\"size\":{\"cols\":40,\"rows\":4},\"history\":0,\"claim\":true,\"colors\":{\"bg\":\"#123456\"}}");
    try w.send(&server, &c);
    try w.settle(&server, &.{&c});
    try p.feed("\x1b]11;?\x07");
    try expect(std.mem.indexOf(u8, p.input.items, "1212/3434/5656") != null);
}

test "present() re-attaches to the current session when the picked one vanished" {
    try @import("attach.zig").TestPresent.run();
}

test "a non-not_found.session failure after a switch is returned, not retried" {
    try @import("attach.zig").TestPresent.runBroken();
}

test "session.get errors map to attach failures and a carried notice is shown" {
    try @import("attach.zig").TestPresent.mapping();
}

test "a failed detach leaves no pending switch and no quit" {
    var fa = std.testing.FailingAllocator.init(a, .{});
    const fa_alloc = fa.allocator();
    var app = try App.init(fa_alloc, .{ .session = "s0" }, .{ .cols = 80, .rows = 24 }, .{});
    defer app.deinit();
    try app.control("{\"id\":2,\"item\":{\"type\":\"stream.checkpoint\",\"data\":{}}}");
    try app.control("{\"id\":2,\"item\":{\"type\":\"window.created\",\"data\":{\"window\":\"w0\",\"session\":\"s0\",\"name\":\"\",\"revision\":1,\"nodes\":[{\"kind\":\"pane\",\"pane\":\"p0\"}]}}}");
    try expect(app.panes.items.len == 1);
    // The id copy succeeds, the detach's first allocation fails.
    fa.fail_index = fa.alloc_index + 1;
    try std.testing.expectError(error.OutOfMemory, app.switchSession("s1"));
    try expect(app.switch_to == null and app.quit == null);
}

test "a layout_changed that cannot carry the name over leaves the window intact" {
    var fa = std.testing.FailingAllocator.init(a, .{});
    var app = try App.init(fa.allocator(), .{ .session = "s0" }, .{ .cols = 80, .rows = 24 }, .{});
    defer app.deinit();
    try app.control("{\"id\":2,\"item\":{\"type\":\"stream.checkpoint\",\"data\":{}}}");
    try app.control("{\"id\":2,\"item\":{\"type\":\"window.created\",\"data\":{\"window\":\"w0\",\"session\":\"s0\",\"name\":\"shell\",\"revision\":1,\"nodes\":[{\"kind\":\"pane\",\"pane\":\"p0\"}]}}}");
    var k: usize = 0;
    while (k < 64) : (k += 1) {
        fa.fail_index = fa.alloc_index + k;
        const rev = k + 2;
        var buf: [256]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "{{\"id\":2,\"item\":{{\"type\":\"window.layout_changed\",\"data\":{{\"window\":\"w0\",\"session\":\"s0\",\"revision\":{d},\"nodes\":[{{\"kind\":\"pane\",\"pane\":\"p0\"}}]}}}}}}", .{rev});
        const ok = if (app.control(line)) true else |err| blk: {
            try std.testing.expectEqual(error.OutOfMemory, err);
            break :blk false;
        };
        fa.fail_index = std.math.maxInt(usize);
        try std.testing.expectEqualStrings("shell", app.windows.items[0].name);
        if (ok) break;
    }
    try expect(k < 64);
}

fn principalEvent(comptime kind: []const u8, comptime resource: []const u8, comptime data: []const u8) []const u8 {
    return "{\"id\":2,\"item\":{\"type\":\"" ++ kind ++ "\",\"resource\":\"" ++ resource ++ "\",\"data\":" ++ data ++ "}}";
}

test "a denied write on a pane of this session is a danger notification; the target pane is untouched" {
    var app = try App.init(a, .{ .session = "s0" }, .{ .cols = 100, .rows = 10 }, .{});
    defer app.deinit();
    app.fixed_now = 1000;
    try app.control(restoredSnapshot(false));
    try app.control(principalEvent("principal.created", "principal:g3", "{\"kind\":\"pane\",\"parent\":\"owner\",\"grants\":[],\"pane\":\"p0\"}"));
    try expect(app.shared.newest(1000) == null);
    try app.control(principalEvent("principal.denied", "principal:g3", "{\"verb\":\"pane.send\",\"right\":\"write\",\"resource\":\"pane:p1\"}"));
    const n = app.shared.newest(1000).?;
    try std.testing.expectEqualStrings("✕ p0 was denied write on p1 (pane.send)", n.text);
    try expectEqual(@import("chrome.zig").NotifyLevel.urgent, n.level);
    try expect(app.shared.pane("p1").?.level == .none);
    try expect(app.shared.newest(1000 + 10_001) == null);
}

test "unknown principal is named by ID; other denials and other sessions show nothing" {
    var app = try App.init(a, .{ .session = "s0" }, .{ .cols = 100, .rows = 10 }, .{});
    defer app.deinit();
    app.fixed_now = 1000;
    try app.control(restoredSnapshot(false));
    try app.control(principalEvent("principal.denied", "principal:g9", "{\"verb\":\"pane.send\",\"right\":\"write\",\"resource\":\"pane:p1\"}"));
    try std.testing.expectEqualStrings("✕ g9 was denied write on p1 (pane.send)", app.shared.newest(1000).?.text);
    app.shared.dismiss("venomx.denied.g9.p1");
    try app.control(principalEvent("principal.denied", "principal:g9", "{\"verb\":\"pane.capture\",\"right\":\"read\",\"resource\":\"pane:p1\"}"));
    try app.control(principalEvent("principal.denied", "principal:g9", "{\"verb\":\"pane.send\",\"right\":\"write\",\"resource\":\"window:w0\"}"));
    try app.control(principalEvent("principal.denied", "principal:g9", "{\"verb\":\"pane.send\",\"right\":\"write\"}"));
    try app.control(principalEvent("principal.denied", "principal:g9", "{\"verb\":\"pane.send\",\"right\":\"write\",\"resource\":\"pane:p77\"}"));
    try expect(app.shared.newest(1000) == null);
}

const denied_write = principalEvent("principal.denied", "principal:g3", "{\"verb\":\"pane.send\",\"right\":\"write\",\"resource\":\"pane:p1\"}");

test "principals seeded from grant.list are named by pane, and by the nearest pane up the chain" {
    var app = try App.init(a, .{ .session = "s0" }, .{ .cols = 100, .rows = 10 }, .{});
    defer app.deinit();
    app.fixed_now = 1000;
    try app.control(restoredSnapshot(false));
    var parsed = try std.json.parseFromSlice(std.json.Value, a, "[{\"principal\":\"g2\",\"parent\":\"owner\",\"pane\":\"p0\"},{\"principal\":\"g3\",\"parent\":\"g2\"}]", .{});
    defer parsed.deinit();
    try app.seedPrincipals(parsed.value);
    try app.control(denied_write);
    try std.testing.expectEqualStrings("✕ p0 was denied write on p1 (pane.send)", app.shared.newest(1000).?.text);
}

test "a revoked principal is named by its ID again" {
    var app = try App.init(a, .{ .session = "s0" }, .{ .cols = 100, .rows = 10 }, .{});
    defer app.deinit();
    app.fixed_now = 1000;
    try app.control(restoredSnapshot(false));
    try app.control(principalEvent("principal.created", "principal:g3", "{\"kind\":\"pane\",\"parent\":\"owner\",\"grants\":[],\"pane\":\"p0\"}"));
    try app.control(principalEvent("principal.revoked", "principal:g3", "{\"reason\":\"revoked\",\"cascade\":0}"));
    try app.control(denied_write);
    try std.testing.expectEqualStrings("✕ g3 was denied write on p1 (pane.send)", app.shared.newest(1000).?.text);
}

test "the principal map is bounded; the oldest goes, the newest stays, nothing leaks" {
    var app = try App.init(a, .{ .session = "s0" }, .{ .cols = 100, .rows = 10 }, .{});
    defer app.deinit();
    const Panes = @import("denied_notice.zig").Panes;
    var i: usize = 0;
    while (i < Panes.max_known + 5) : (i += 1) {
        const id = try std.fmt.allocPrint(a, "g{d}", .{i + 10});
        defer a.free(id);
        try app.principal_panes.learn(a, id, "p0", "owner");
    }
    try expectEqual(Panes.max_known, app.principal_panes.list.items.len);
    try expect(app.principal_panes.paneOf("g10") == null);
    try expect(app.principal_panes.paneOf("g270") != null);
}

test "a pane attach shows a denial on its own pane only; raw shows nothing" {
    var app = try App.init(a, .{ .pane = "p1" }, .{ .cols = 100, .rows = 10 }, .{});
    defer app.deinit();
    app.fixed_now = 1000;
    try app.control(principalEvent("principal.denied", "principal:g3", "{\"verb\":\"pane.send\",\"right\":\"write\",\"resource\":\"pane:p2\"}"));
    try expect(app.shared.newest(1000) == null);
    try app.control(denied_write);
    try std.testing.expectEqualStrings("✕ g3 was denied write on p1 (pane.send)", app.shared.newest(1000).?.text);
    var raw = try App.init(a, .{ .pane = "p1" }, .{ .cols = 100, .rows = 10 }, .{});
    defer raw.deinit();
    raw.raw = true;
    raw.fixed_now = 1000;
    try raw.control(denied_write);
    try expect(raw.shared.newest(1000) == null);
}

test "the pane's cursor shape reaches the host cursor, from the snapshot and live" {
    var server = Server.init(a, "venomx/test");
    defer server.deinit();
    server.authorize = writer;
    const p = try server.createPane(.{ .cols = 40, .rows = 5 });
    // Insert mode before the client attaches: the snapshot carries it.
    try p.feed("$ vim\r\n\x1b[6 q");
    var w = try Wire.init(1 << 20);
    defer w.deinit(&server);
    var app = try App.init(a, .{ .pane = "p0" }, .{ .cols = 40, .rows = 6 }, .{});
    defer app.deinit();
    try app.resize(40, 6);
    try exchange(&server, &w, &app);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var surface = try term.Surface.init(a, app.cols, app.rows);
    defer surface.deinit(&out.writer);
    try app.render(&surface);
    try std.testing.expectEqual(term.Vt.CursorShape{ .kind = .bar }, surface.cursor.?.shape);
    // Esc to normal mode changes only the shape, and the client redraws.
    try p.feed("\x1b[2 q");
    try exchange(&server, &w, &app);
    try expect(app.needsRender());
    try app.render(&surface);
    try std.testing.expectEqual(term.Vt.CursorShape{ .kind = .block }, surface.cursor.?.shape);
    // Leaving vim resets it: the host keeps its own cursor.
    try p.feed("\x1b[0 q");
    try exchange(&server, &w, &app);
    try app.render(&surface);
    try std.testing.expectEqual(term.Vt.CursorShape{}, surface.cursor.?.shape);
}

test "shifted keys from a Kitty host reach a Kitty-mode pane as their text" {
    var app = try readyInputApp();
    defer app.deinit();
    const p = app.pane("p0").?;
    // nvim's disambiguate mode.
    try p.stream.vt.?.feed("\x1b[>1u");
    const shift = "\x1b[57441;2u";
    const unshift = "\x1b[57441;2:3u";
    const cases = [_]struct { host: []const u8, want: []const u8 }{
        .{ .host = ":", .want = ":" },
        .{ .host = "\x1b[59:58;2;58u", .want = ":" },
        .{ .host = shift ++ "\x1b[59:58;2;58u\x1b[59:58;2:3u" ++ unshift, .want = ":" },
        .{ .host = "\x1b[53:37;2;37u", .want = "%" },
        .{ .host = "\x1b[97:65;2;65u", .want = "A" },
        .{ .host = "\x1b[47:63;2;63u", .want = "?" },
    };
    for (cases) |case| {
        _ = try app.feedInput(case.host);
        _ = try expectInputs(p, case.want);
    }
}

test "a synchronized-output frame is drawn whole, cursor included, or after the limit" {
    var server = Server.init(a, "venomx/test");
    defer server.deinit();
    server.authorize = writer;
    const p = try server.createPane(.{ .cols = 40, .rows = 5 });
    try p.feed("> ");
    var w = try Wire.init(1 << 20);
    defer w.deinit(&server);
    var app = try App.init(a, .{ .pane = "p0" }, .{ .cols = 40, .rows = 6 }, .{});
    defer app.deinit();
    app.fixed_now = 1000;
    try app.resize(40, 6);
    try exchange(&server, &w, &app);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var surface = try term.Surface.init(a, app.cols, app.rows);
    defer surface.deinit(&out.writer);
    try app.render(&surface);
    // Codex's animation frame: redraw rows with the cursor visible, then
    // put it back on the input line. Mid-frame, nothing is drawn.
    try p.feed("\x1b[?2026h\x1b[4;30Hlogo\x1b[2;10Hlogo");
    try exchange(&server, &w, &app);
    try expect(!app.needsRender());
    try std.testing.expectEqual(@as(?i64, 1000 + app_mod.sync_limit_ms), app.nextWake());
    try p.feed("\x1b[1;3H\x1b[?2026l");
    try exchange(&server, &w, &app);
    try expect(app.needsRender());
    try app.render(&surface);
    const r = app.pane("p0").?.rect;
    try std.testing.expectEqual(r.x + 2, surface.cursor.?.x);
    try std.testing.expectEqual(r.y, surface.cursor.?.y);
    // A program that never ends its frame is drawn once the limit passes.
    try p.feed("\x1b[?2026h\x1b[3;5Hstuck");
    try exchange(&server, &w, &app);
    try expect(!app.needsRender());
    app.fixed_now = 1000 + app_mod.sync_limit_ms;
    try expect(app.needsRender());
}

test "a scrolled pane keeps its cursor while the cursor's row is in view" {
    var app = try readyInputApp();
    defer app.deinit();
    const p = app.pane("p0").?;
    var line: [32]u8 = undefined;
    for (0..20) |i| try p.stream.vt.?.feed(try std.fmt.bufPrint(&line, "row {d}\r\n", .{i}));
    try p.stream.vt.?.feed("\x1b[2;3H");
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var surface = try term.Surface.init(a, app.cols, app.rows);
    defer surface.deinit(&out.writer);
    try app.run(.{ .local = .scroll_line_up });
    try expect(p.scroll != null);
    try app.render(&surface);
    const cur = surface.cursor.?;
    try expectEqual(p.rect.x + 2, cur.x);
    try expectEqual(p.rect.y + 2, cur.y);
    // Scrolled far enough that its row is gone, the cursor is too.
    try app.run(.{ .local = .scroll_page_up });
    try app.render(&surface);
    try expect(surface.cursor == null);
}

test "Ctrl+Shift+C copies the selection after Ctrl and Shift alone and never reaches the pane" {
    var app = try readyInputApp();
    defer app.deinit();
    const p = app.pane("p0").?;
    var line: [32]u8 = undefined;
    for (0..20) |i| try p.stream.vt.?.feed(try std.fmt.bufPrint(&line, "row {d}\r\n", .{i}));
    try p.stream.vt.?.feed("hello world");
    // Select "hello" on the pane's last row (host row 6; row 1 is the status line).
    _ = try app.feedInput("\x1b[<0;1;6M\x1b[<32;5;6M\x1b[<0;5;6m");
    try expect(p.selection != null);
    app.host.clearRetainingCapacity();
    // A Kitty host reporting all keys: Ctrl, Shift, c with both, releases.
    _ = try app.feedInput("\x1b[57442;5u\x1b[57441;6u\x1b[99;6u\x1b[99;6:3u\x1b[57441;6:3u\x1b[57442;5:3u");
    try expect(p.selection != null);
    try std.testing.expectEqualStrings("\x1b]52;c;aGVsbG8=\x07", app.host.items);
    _ = try expectInputs(p, "");
    // Ctrl alone keeps the scroll position too; typing returns to live.
    try app.run(.{ .local = .scroll_page_up });
    _ = try app.feedInput("\x1b[57442;5u\x1b[57442;5:3u");
    try expect(p.scroll != null);
    _ = try expectInputs(p, "");
    _ = try app.feedInput("x");
    try expect(p.scroll == null and p.selection == null);
    _ = try expectInputs(p, "x");
    // With no selection the chord is the pane's, as on a host with none.
    _ = try app.feedInput("\x1b[99;6u");
    try expect(p.stream.outbox.items.len > 0);
}

test "leader [ v enters copy mode; vi motions select, y copies with OSC 52 and leaves" {
    var app = try readyInputApp();
    defer app.deinit();
    const p = app.pane("p0").?;
    var line: [32]u8 = undefined;
    for (0..20) |i| try p.stream.vt.?.feed(try std.fmt.bufPrint(&line, "row {d}\r\n", .{i}));
    try p.stream.vt.?.feed("$ ");
    _ = try app.feedInput("\x02[v");
    try expect(p.copy != null);
    try expect(!app.leaderPending());
    {
        const t = try render(&app);
        defer a.free(t);
        try expect(std.mem.indexOf(u8, t, "COPY") != null);
    }
    // The cursor starts on the pane's: row "$ ", column 2.
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var surface = try term.Surface.init(a, app.cols, app.rows);
    defer surface.deinit(&out.writer);
    try app.render(&surface);
    try expectEqual(p.rect.x + 2, surface.cursor.?.x);
    try expectEqual(p.rect.y + p.rect.height - 1, surface.cursor.?.y);
    // Up to "row 19", select its first word, yank.
    _ = try app.feedInput("k0vey");
    try std.testing.expectEqualStrings("\x1b]52;c;cm93\x07", app.host.items);
    try expect(p.copy == null and p.selection == null and p.scroll == null);
    _ = try expectInputs(p, "");
    // Motions past the view scroll it; the copy cursor stays drawn.
    app.host.clearRetainingCapacity();
    _ = try app.feedInput("\x02[v10k");
    try expect(p.scroll != null);
    try app.render(&surface);
    try expectEqual(term.Vt.CursorShape{ .kind = .block }, surface.cursor.?.shape);
    try expectEqual(p.rect.y, surface.cursor.?.y);
    // Line selection over two rows: "row 10" and "row 11".
    _ = try app.feedInput("Vjy");
    try std.testing.expectEqualStrings("\x1b]52;c;cm93IDEwCnJvdyAxMQ==\x07", app.host.items);
    // q leaves without copying and returns to live.
    app.host.clearRetainingCapacity();
    _ = try app.feedInput("\x02[vggq");
    try expect(p.copy == null and p.scroll == null);
    try expectEqual(@as(usize, 0), app.host.items.len);
    _ = try expectInputs(p, "");
}

test "copy mode / searches the history, shows the line, highlights matches; n repeats" {
    var app = try readyInputApp();
    defer app.deinit();
    const p = app.pane("p0").?;
    var line: [32]u8 = undefined;
    for (0..20) |i| try p.stream.vt.?.feed(try std.fmt.bufPrint(&line, "row {d}\r\n", .{i}));
    try p.stream.vt.?.feed("$ ");
    _ = try app.feedInput("\x02[v/row 1");
    // The search line replaces the status line while it is typed.
    {
        const t = try render(&app);
        defer a.free(t);
        try expect(std.mem.startsWith(u8, t, "/row 1"));
    }
    // From the prompt row it wraps to the top: "row 1", then "row 10".
    _ = try app.feedInput("\r");
    const one = p.copy.?.cursor;
    try expectEqual(@as(u16, 0), one.col);
    _ = try app.feedInput("n");
    const ten = p.copy.?.cursor;
    try expectEqual(one.row + 9, ten.row);
    _ = try app.feedInput("v$y");
    try std.testing.expectEqualStrings("\x1b]52;c;cm93IDEw\x07", app.host.items);
    _ = try expectInputs(p, "");
    // Back in copy mode the search is new; a miss says so and stays.
    _ = try app.feedInput("\x02[v?nope\r");
    try expect(p.copy != null);
    try expect(std.mem.indexOf(u8, app.message.items, "pattern not found: nope") != null);
    // ? finds "row 19" just above the prompt; its cells are drawn on warn.
    _ = try app.feedInput("?row 19\r");
    const at = p.copy.?.cursor;
    try expect(at.row == ten.row + 9 and at.col == 0);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var surface = try term.Surface.init(a, app.cols, app.rows);
    defer surface.deinit(&out.writer);
    try app.render(&surface);
    const y: u16 = @intCast(p.rect.y + (at.row - app.topRow(p)));
    const want = app.chrome.fill(app.chrome.theme.void, app.chrome.theme.warn);
    try expect(std.meta.eql(want, surface.get(p.rect.x + 1, y).?.style));
    try expect(!std.meta.eql(want, surface.get(p.rect.x + 7, y).?.style));
}
