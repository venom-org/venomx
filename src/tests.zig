const std = @import("std");
const s = @import("stream.zig");
const a = std.testing.allocator;
test "two clients receive exact raw bytes and slow client resyncs independently" {
    const p = try s.Pane.create(a, "p0", .{ .cols = 20, .rows = 4 }, .{});
    defer p.destroy();
    const fast = try s.Stream.create(p, "venomx/test", .{}, .{}, 0);
    defer fast.destroy();
    const slow = try s.Stream.create(p, "venomx/test", .{}, .{}, 0);
    defer slow.destroy();
    try drain(fast, 0);
    try drain(slow, 0);
    const bytes = "hello\x1b[31m world\x1b[0m\r\n";
    try p.feed(bytes);
    for ([_]*s.Stream{ fast, slow }) |client| {
        const f = (try client.next(4096, 0)).?;
        defer f.deinit(a);
        try std.testing.expectEqual(s.Kind.pty, f.kind);
        try std.testing.expectEqualStrings(bytes, f.payload[8..]);
    }
    var block: [4096]u8 = @splat('x');
    // One block more than the ring holds, so the idle client is past its tail.
    for (0..p.config.ring_bytes / block.len + 1) |_| {
        try p.feed(&block);
        try drain(fast, 0);
    }
    try std.testing.expectEqual(p.ring.head, fast.send_offset);
    const resync = (try slow.next(4096, 1001)).?;
    defer resync.deinit(a);
    try std.testing.expectEqual(s.Kind.resync, resync.kind);
    try std.testing.expect(std.mem.indexOf(u8, resync.payload, "overflow") != null);
    try drain(slow, 1001);
    try std.testing.expectEqual(p.ring.head, slow.send_offset);
}
fn drain(client: *s.Stream, now: i64) !void {
    for (0..10000) |_| {
        const frame = (try client.next(4096, now)) orelse return;
        frame.deinit(a);
    }
    return error.NeverIdle;
}

test "PTY frames stop at the frame cap and at a smaller max_frame, contiguously" {
    const p = try s.Pane.create(a, "p0", .{ .cols = 20, .rows = 4 }, .{});
    defer p.destroy();
    const client = try s.Stream.create(p, "venomx/test", .{}, .{}, 0);
    defer client.destroy();
    try drain(client, 0);
    var block: [65536]u8 = @splat('x');
    for ([_]u32{ 1024 * 1024, 4096 }) |max_frame| {
        const start = p.ring.head;
        for (0..12) |_| try p.feed(&block);
        const limit = @min(max_frame, s.pty_frame_max);
        var at = start;
        var full: usize = 0;
        while (at < p.ring.head) {
            const f = (try client.next(max_frame, 0)).?;
            defer f.deinit(a);
            try std.testing.expectEqual(s.Kind.pty, f.kind);
            try std.testing.expect(f.payload.len <= limit);
            try std.testing.expectEqual(at, std.mem.readInt(u64, f.payload[0..8], .big));
            at += f.payload.len - 8;
            if (f.payload.len == limit) full += 1;
        }
        try std.testing.expect(full >= 2);
        try std.testing.expectEqual(p.ring.head, client.send_offset);
    }
}

test "reconnect resumes bytes and resize at offset; invalid source snapshots" {
    const p = try s.Pane.create(a, "p0", .{ .cols = 80, .rows = 24 }, .{ .resize_coalesce_ms = 0 });
    defer p.destroy();
    try p.feed("before");
    const writer = try s.Stream.create(p, "venomx/test", .{ .size = .{ .cols = 100, .rows = 30 } }, .{ .write = true }, 0);
    defer writer.destroy();
    try p.feed("after");
    const c = try s.Stream.create(p, "venomx/test", .{ .claim = false, .@"resume" = .{ .source = "venomx/test", .offset = 6 } }, .{}, 0);
    defer c.destroy();
    const attached = (try c.next(4096, 0)).?;
    defer attached.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, attached.payload, "\"resumed\":true") != null);
    const resize = (try c.next(4096, 0)).?;
    defer resize.deinit(a);
    try std.testing.expectEqual(s.Kind.resize, resize.kind);
    const bytes = (try c.next(4096, 0)).?;
    defer bytes.deinit(a);
    try std.testing.expectEqual(s.Kind.pty, bytes.kind);
    try std.testing.expectEqualStrings("after", bytes.payload[8..]);
    const stale = try s.Stream.create(p, "venomx/new", .{ .@"resume" = .{ .source = "venomx/test", .offset = 6 } }, .{}, 0);
    defer stale.destroy();
    try std.testing.expect(!stale.resumed);
    try drain(stale, 0);
}

test "watcher input is denied; writer frames and authoritative query replies serialize" {
    const p = try s.Pane.create(a, "p0", .{ .cols = 80, .rows = 24 }, .{});
    defer p.destroy();
    const watcher = try s.Stream.create(p, "venomx/test", .{}, .{}, 0);
    defer watcher.destroy();
    try drain(watcher, 0);
    try watcher.inputBytes("forbidden", 0);
    const denied = (try watcher.next(4096, 0)).?;
    defer denied.deinit(a);
    try std.testing.expectEqual(@as(u16, 3), denied.kind);
    try std.testing.expect(std.mem.indexOf(u8, denied.payload, "denied.write") != null);
    try std.testing.expectEqual(@as(usize, 0), p.input.items.len);
    const w1 = try s.Stream.create(p, "venomx/test", .{}, .{ .write = true }, 0);
    defer w1.destroy();
    const w2 = try s.Stream.create(p, "venomx/test", .{}, .{ .write = true }, 0);
    defer w2.destroy();
    try w1.inputBytes("first", 0);
    try p.feed("\x1b[6n");
    try w2.inputBytes("second", 0);
    try std.testing.expectEqualStrings("first\x1b[1;1Rsecond", p.input.items);
}

test "latest size hold, geometry does not claim, coalescing flushes before input" {
    const p = try s.Pane.create(a, "p0", .{ .cols = 80, .rows = 24 }, .{});
    defer p.destroy();
    const first = try s.Stream.create(p, "test", .{ .size = .{ .cols = 100, .rows = 30 } }, .{ .write = true }, 0);
    defer first.destroy();
    const second = try s.Stream.create(p, "test", .{ .size = .{ .cols = 120, .rows = 40 } }, .{ .write = true }, 100);
    defer second.destroy();
    try std.testing.expectEqual(@as(u16, 100), p.vt.size().cols);
    try second.viewport(.{ .cols = 140, .rows = 50 }, 1500);
    try std.testing.expectEqual(@as(u16, 100), p.vt.size().cols);
    try second.inputBytes("x", 1501);
    try std.testing.expectEqual(@as(u16, 140), p.vt.size().cols);
    try second.viewport(.{ .cols = 145, .rows = 51 }, 1502);
    try second.viewport(.{ .cols = 150, .rows = 52 }, 1503);
    try std.testing.expectEqual(@as(u16, 140), p.vt.size().cols);
    try second.inputBytes("y", 1504);
    try std.testing.expectEqual(@as(u16, 150), p.vt.size().cols);
    const watcher = try s.Stream.create(p, "test", .{ .size = .{ .cols = 1, .rows = 1 } }, .{}, 4000);
    defer watcher.destroy();
    try std.testing.expectEqual(@as(u16, 150), p.vt.size().cols);
}

test "transport enforces capability and read grant and generates lazy frames" {
    const proto = @import("proto");
    const Server = @import("server.zig").Server;
    var server = Server.init(a, "venomx/test");
    defer server.deinit();
    const p = try server.createPane(.{ .cols = 80, .rows = 24 });
    var conn = proto.Connection.init(a, -1);
    defer conn.deinit();
    // Must drop connection state before deinitializing the borrowed connection.
    defer server.closed(&conn);
    conn.protocol = .binary;
    conn.ready = true;
    try std.testing.expect(!server.allowFrame(&conn, s.Kind.attach));
    try conn.caps.append(a, s.capability);
    try server.message(&conn, .{ .frame = .{ .kind = s.Kind.attach, .stream = 1, .payload = "{\"pane\":\"p0\",\"mode\":\"emulate\",\"formats\":[\"vt\"],\"size\":{\"cols\":80,\"rows\":24}}" } });
    try std.testing.expectEqual(@as(usize, 0), conn.output.items.len);
    try server.pump(0);
    try std.testing.expectEqual(@as(u16, s.Kind.attached), std.mem.readInt(u16, conn.output.items[0..2], .big));
    const queued = conn.output.items.len;
    try p.feed("more");
    try server.pump(0);
    try std.testing.expectEqual(queued, conn.output.items.len);
}

test "snapshots restore a live client and epoch changes abort history" {
    const Vt = @import("vt").Vt;
    const p = try s.Pane.create(a, "p0", .{ .cols = 30, .rows = 4 }, .{});
    defer p.destroy();
    for (0..2000) |_| try p.feed("history line\r\n");
    const client = try s.Stream.create(p, "test", .{}, .{}, 0);
    defer client.destroy();
    var decoder = try Vt.Decoder.init(a, .{});
    var live: ?Vt = null;
    defer if (live) |*v| v.deinit() else decoder.deinit();
    var ready = false;
    for (0..1000) |_| {
        const frame = (try client.next(1024 * 1024, 0)).?;
        defer frame.deinit(a);
        if (frame.kind == s.Kind.snapshot) try decoder.feedPrefix(frame.payload[12..]);
        if (frame.kind == s.Kind.ready) {
            live = try decoder.ready(client.ready);
            ready = true;
            break;
        }
    }
    try std.testing.expect(ready);
    try p.feed("LIVE");
    const output = (try client.next(1024 * 1024, 0)).?;
    defer output.deinit(a);
    try std.testing.expectEqual(s.Kind.pty, output.kind);
    try live.?.feed(output.payload[8..]);
    // History never delays live output and its absolute addresses descend.
    var previous_end = client.ready.top;
    var count: usize = 0;
    var history_rows: u64 = 0;
    while (try client.next(1024 * 1024, 0)) |frame| {
        defer frame.deinit(a);
        if (frame.kind != s.Kind.scrollback) continue;
        const end = std.mem.readInt(u64, frame.payload[8..16], .big);
        const rows = std.mem.readInt(u32, frame.payload[16..20], .big);
        try std.testing.expectEqual(previous_end, end);
        previous_end = end - rows;
        history_rows += rows;
        if (frame.payload.len > 21) _ = try live.?.feedHistory(frame.payload[21..]);
        count += 1;
        if (frame.payload[20] & 1 != 0) {
            live.?.abandonHistory();
            break;
        }
    }
    try std.testing.expect(count > 0);
    try std.testing.expect(history_rows > 0);
    const r = p.vt.rows();
    const expected = try p.vt.exportRows(a, r.epoch, r.active, r.end);
    defer a.free(expected);
    const lr = live.?.rows();
    const actual = try live.?.exportRows(a, lr.epoch, lr.active, lr.end);
    defer a.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
    client.requestResync();
    // Stop immediately after new READY, then cause a new epoch.
    while (true) {
        const f = (try client.next(1024 * 1024, 1001)).?;
        defer f.deinit(a);
        if (f.kind == s.Kind.ready) break;
    }
    try p.feed("\x1bc");
    const bytes = (try client.next(1024 * 1024, 1001)).?;
    bytes.deinit(a);
    const aborted = (try client.next(1024 * 1024, 1001)).?;
    defer aborted.deinit(a);
    try std.testing.expectEqual(s.Kind.scrollback, aborted.kind);
    try std.testing.expectEqual(@as(u8, 3), aborted.payload[20]);
}

test "raw VT snapshot replays unfinished bytes at ground offset" {
    const p = try s.Pane.create(a, "p0", .{ .cols = 20, .rows = 4 }, .{});
    defer p.destroy();
    try p.feed("ok\x1b[3");
    const c = try s.Stream.create(p, "test", .{ .mode = .raw, .format = .vt }, .{}, 0);
    defer c.destroy();
    while (true) {
        const f = (try c.next(4096, 0)).?;
        defer f.deinit(a);
        if (f.kind == s.Kind.ready) break;
    }
    try std.testing.expectEqual(@as(u64, 2), c.snap_offset);
    const bytes = (try c.next(4096, 0)).?;
    defer bytes.deinit(a);
    try std.testing.expectEqualStrings("\x1b[3", bytes.payload[8..]);
    const last = (try c.next(4096, 0)).?;
    defer last.deinit(a);
    try std.testing.expectEqual(@as(u8, 1), last.payload[20]);
}

test "real PTY and two negotiated Unix socket clients share the stream" {
    const proto = @import("proto");
    const transport = @import("server.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const parent = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}", .{tmp.sub_path}, 0);
    defer a.free(parent);
    try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(parent, 0o700));
    const path = try std.fmt.allocPrint(a, "{s}/stream.sock", .{parent});
    defer a.free(path);
    var app = transport.Server.init(a, "venomx/test");
    defer app.deinit();
    var server = try proto.Server.init(a, .{ .hello = .{ .identity = .{ .name = "venomx", .version = "0" }, .caps = &.{s.capability} }, .path = .{ .socket = path } }, app.handler());
    defer server.deinit();
    const pane = try app.createPane(.{ .cols = 80, .rows = 24 });
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", "printf initial; read line; printf 'RESULT:%s' \"$line\"" };
    try pane.spawn(&argv);
    const Auth = struct {
        fn grant(_: ?*anyopaque, _: *const proto.Connection, _: []const u8) s.Grants {
            return .{ .write = true };
        }
    };
    app.authorize = Auth.grant;
    const options: proto.ClientOptions = .{ .tool = "venomx", .path = .{ .socket = path }, .protocol = .binary, .hello = .{ .identity = .{ .name = "test", .version = "0" }, .caps = &.{s.capability} } };
    var one = try proto.Client.init(a, options);
    defer one.deinit();
    var two = try proto.Client.init(a, options);
    defer two.deinit();
    const deadline = transport.nowMs() + 5000;
    while (!one.connection.ready or !two.connection.ready) {
        if (transport.nowMs() >= deadline) return error.TestTimeout;
        try server.poll(0);
        _ = try one.pollHello(1);
        _ = try two.pollHello(1);
        try app.pump(transport.nowMs());
    }
    const attach = "{\"pane\":\"p0\",\"mode\":\"emulate\",\"formats\":[\"vt\"],\"history\":0,\"size\":{\"cols\":80,\"rows\":24}}";
    for ([_]*proto.Client{ &one, &two }) |c| try c.connection.sendMessage(.{ .frame = .{ .kind = s.Kind.attach, .stream = 1, .payload = attach } });
    var ready = [_]bool{ false, false };
    while (!ready[0] or !ready[1]) {
        if (transport.nowMs() >= deadline) return error.TestTimeout;
        try server.poll(0);
        try app.pump(transport.nowMs());
        for ([_]*proto.Client{ &one, &two }, 0..) |c, i| if (try c.receive(1)) |msg| {
            if (msg.frame.kind == s.Kind.ready) ready[i] = true;
        };
    }
    try one.connection.sendMessage(.{ .frame = .{ .kind = s.Kind.input, .stream = 1, .payload = "hello\n" } });
    var received = [_]std.ArrayList(u8){ .empty, .empty };
    defer for (&received) |*buf| buf.deinit(a);
    var exited = [_]bool{ false, false };
    while (!exited[0] or !exited[1]) {
        if (transport.nowMs() >= deadline) return error.TestTimeout;
        try server.poll(0);
        try app.pump(transport.nowMs());
        for ([_]*proto.Client{ &one, &two }, 0..) |c, i| if (try c.receive(1)) |msg| {
            if (msg.frame.kind == s.Kind.pty) try received[i].appendSlice(a, msg.frame.payload[8..]);
            if (msg.frame.kind == s.Kind.exit) exited[i] = true;
        };
    }
    try std.testing.expectEqualStrings(received[0].items, received[1].items);
    try std.testing.expect(std.mem.indexOf(u8, received[0].items, "RESULT:hello") != null);
}

test "smallest uses only writers, fixed ignores clients, detach retains size" {
    inline for (.{ s.Policy.smallest, s.Policy.fixed }) |policy| {
        const p = try s.Pane.create(a, "p0", .{ .cols = 80, .rows = 24 }, .{ .size_policy = policy, .resize_coalesce_ms = 0 });
        defer p.destroy();
        const first = try s.Stream.create(p, "test", .{ .size = .{ .cols = 100, .rows = 20 } }, .{ .write = true }, 0);
        const second = try s.Stream.create(p, "test", .{ .size = .{ .cols = 90, .rows = 30 } }, .{ .write = true }, 100);
        const watcher = try s.Stream.create(p, "test", .{ .size = .{ .cols = 1, .rows = 1 } }, .{}, 200);
        watcher.destroy();
        const expected: s.Size = if (policy == .fixed) .{ .cols = 120, .rows = 40 } else .{ .cols = 90, .rows = 20 };
        try std.testing.expectEqual(expected, p.vt.size());
        first.destroy();
        second.destroy();
        try std.testing.expectEqual(expected, p.vt.size());
    }
}

test "host colors follow active writer and never a watcher" {
    const p = try s.Pane.create(a, "p0", .{ .cols = 80, .rows = 24 }, .{});
    defer p.destroy();
    const first = try s.Stream.create(p, "test", .{ .colors = .{ .fg = .{ 0x11, 0x22, 0x33 } } }, .{ .write = true }, 0);
    defer first.destroy();
    const second = try s.Stream.create(p, "test", .{ .colors = .{ .fg = .{ 0xaa, 0xbb, 0xcc } } }, .{ .write = true }, 1);
    defer second.destroy();
    const watcher = try s.Stream.create(p, "test", .{ .colors = .{ .fg = .{ 0xff, 0xff, 0xff } } }, .{}, 2);
    defer watcher.destroy();
    try p.feed("\x1b]10;?\x07");
    try std.testing.expect(std.mem.indexOf(u8, p.input.items, "1111/2222/3333") != null);
    p.input.clearRetainingCapacity();
    try second.inputBytes("", 1001);
    try p.feed("\x1b]10;?\x07");
    try std.testing.expect(std.mem.indexOf(u8, p.input.items, "aaaa/bbbb/cccc") != null);
}

test "ring reload and invalid resume fall back without affecting other streams" {
    const p = try s.Pane.create(a, "p0", .{ .cols = 80, .rows = 24 }, .{});
    defer p.destroy();
    var block: [4096]u8 = @splat('x');
    for (0..32) |_| try p.feed(&block);
    try p.reconfigure(.{ .ring_bytes = 65536, .client_backlog_bytes = 65536 });
    try std.testing.expectEqual(@as(u64, 0), p.ring.tail);
    try p.feed("x");
    try std.testing.expect(p.ring.tail > 0);
    for ([_]u64{ 0, p.ring.head + 1 }) |offset| {
        const c = try s.Stream.create(p, "test", .{ .@"resume" = .{ .source = "test", .offset = offset } }, .{}, 0);
        defer c.destroy();
        try std.testing.expect(!c.resumed);
    }
    try std.testing.expectError(error.InvalidConfig, p.reconfigure(.{ .ring_bytes = 1 }));
    try std.testing.expectError(error.DeniedRead, s.Stream.create(p, "test", .{}, .{ .read = false }, 0));
}

test "watcher transport denial, removed panes close after pending frame, IDs never reused" {
    const proto = @import("proto");
    const Server = @import("server.zig").Server;
    var server = Server.init(a, "venomx/test");
    defer server.deinit();
    const pane = try server.createPane(.{ .cols = 80, .rows = 24 });
    var conn = proto.Connection.init(a, -1);
    defer conn.deinit();
    defer server.closed(&conn);
    conn.protocol = .binary;
    conn.ready = true;
    try conn.caps.append(a, s.capability);
    const attach = "{\"pane\":\"p0\",\"mode\":\"emulate\",\"formats\":[\"vt\"],\"size\":{\"cols\":80,\"rows\":24},\"write\":true}";
    try server.message(&conn, .{ .frame = .{ .kind = s.Kind.attach, .stream = 1, .payload = attach } });
    try server.pump(0);
    try server.message(&conn, .{ .frame = .{ .kind = s.Kind.input, .stream = 1, .payload = "forbidden" } });
    try std.testing.expectEqual(@as(usize, 0), pane.input.items.len);
    conn.output.clearRetainingCapacity();
    try server.pump(0);
    try std.testing.expect(std.mem.indexOf(u8, conn.output.items, "denied.write") != null);
    conn.output.clearRetainingCapacity();
    try server.message(&conn, .{ .frame = .{ .kind = s.Kind.attach, .stream = 3, .payload = attach } });
    try server.pump(0);
    const pending_len = conn.output.items.len;
    server.removePane(pane);
    try server.pump(0);
    try std.testing.expectEqual(pending_len, conn.output.items.len);
    conn.output.clearRetainingCapacity();
    try server.pump(0);
    try std.testing.expectEqual(@as(u16, proto.Kind.close), std.mem.readInt(u16, conn.output.items[0..2], .big));
    try std.testing.expectEqual(@as(usize, 0), server.panes.items.len);
    const next = try server.createPane(.{ .cols = 80, .rows = 24 });
    try std.testing.expectEqualStrings("p1", next.id);
}

test "a RESYNC without claim is not activity and a RESYNC with claim is" {
    const proto = @import("proto");
    const Server = @import("server.zig").Server;
    var server = Server.init(a, "venomx/test");
    defer server.deinit();
    server.authorize = struct {
        fn f(_: ?*anyopaque, _: *const proto.Connection, _: []const u8) s.Grants {
            return .{ .write = true };
        }
    }.f;
    const p = try server.createPane(.{ .cols = 80, .rows = 24 });
    p.config.latest_hold_ms = 0;
    p.config.resize_coalesce_ms = 0;
    var conn = proto.Connection.init(a, -1);
    defer conn.deinit();
    defer server.closed(&conn);
    conn.protocol = .binary;
    conn.ready = true;
    try conn.caps.append(a, s.capability);
    const attach1 = "{\"pane\":\"p0\",\"mode\":\"emulate\",\"formats\":[\"vt\"],\"size\":{\"cols\":100,\"rows\":30},\"claim\":true}";
    const attach2 = "{\"pane\":\"p0\",\"mode\":\"emulate\",\"formats\":[\"vt\"],\"size\":{\"cols\":120,\"rows\":40},\"claim\":true}";
    try server.message(&conn, .{ .frame = .{ .kind = s.Kind.attach, .stream = 1, .payload = attach1 } });
    try server.message(&conn, .{ .frame = .{ .kind = s.Kind.attach, .stream = 3, .payload = attach2 } });
    for (0..50) |_| {
        try server.pump(0);
        conn.output.clearRetainingCapacity();
    }
    var live: usize = 0;
    for (server.attachments.items) |att| {
        if (att.stream.phase == .live) live += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), live);
    // The second writer holds the pane (hold 0: the latest attach took it).
    try std.testing.expectEqual(@as(u16, 120), p.vt.size().cols);
    // Writer 1 resyncs with a new viewport but no claim: nothing moves.
    try server.message(&conn, .{ .frame = .{ .kind = s.Kind.resync, .stream = 1, .payload = "{\"size\":{\"cols\":90,\"rows\":20}}" } });
    try std.testing.expectEqual(@as(u16, 120), p.vt.size().cols);
    try std.testing.expect(p.active == server.attachments.items[1].stream);
    for (0..50) |_| {
        try server.pump(0);
        conn.output.clearRetainingCapacity();
    }
    // An explicit claim does count.
    try server.message(&conn, .{ .frame = .{ .kind = s.Kind.resync, .stream = 1, .payload = "{\"size\":{\"cols\":90,\"rows\":20},\"claim\":true}" } });
    try std.testing.expectEqual(@as(u16, 90), p.vt.size().cols);
    try std.testing.expect(p.active == server.attachments.items[0].stream);
}

test "a pane clusters graphemes, and a client's snapshot keeps mode 2027" {
    const Vt = @import("vt").Vt;
    const p = try s.Pane.create(a, "p0", .{ .cols = 20, .rows = 4 }, .{});
    defer p.destroy();
    // A Devanagari conjunct (क्षि) is one cluster, two cells wide.
    try p.feed("क्षि");
    try std.testing.expectEqual(@as(u16, 2), p.vt.cursor().x);
    try p.feed("\x1b[?2027$p");
    try std.testing.expectEqualStrings("\x1b[?2027;1$y", p.input.items);
    const client = try s.Stream.create(p, "test", .{}, .{}, 0);
    defer client.destroy();
    var decoder = try Vt.Decoder.init(a, .{});
    var live: ?Vt = null;
    defer if (live) |*v| v.deinit() else decoder.deinit();
    for (0..1000) |_| {
        const frame = (try client.next(1024 * 1024, 0)).?;
        defer frame.deinit(a);
        if (frame.kind == s.Kind.snapshot) try decoder.feedPrefix(frame.payload[12..]);
        if (frame.kind == s.Kind.ready) {
            live = try decoder.ready(client.ready);
            break;
        }
    }
    try std.testing.expectEqual(@as(u16, 2), live.?.cursor().x);
    try live.?.feed("\r\nक्षि");
    try std.testing.expectEqual(@as(u16, 2), live.?.cursor().x);
}

test "a pane answers DA1, XTVERSION, TN and the colour scheme" {
    const p = try s.Pane.create(a, "p0", .{ .cols = 80, .rows = 24 }, .{});
    defer p.destroy();
    try p.setTerminfo("xterm-256color");
    try p.feed("\x1b[c\x1b[>q\x1bP+q544e\x1b\\");
    try std.testing.expectEqualStrings("\x1b[?62;22;52c\x1bP>|" ++ s.xtversion ++ "\x1b\\\x1bP1+r544E=787465726D2D323536636F6C6F72\x1b\\", p.input.items);
    try std.testing.expect(std.mem.startsWith(u8, s.xtversion, "venomx "));
    // No background known: the scheme query goes unanswered.
    p.input.clearRetainingCapacity();
    try p.feed("\x1b[?996n");
    try std.testing.expectEqualStrings("", p.input.items);
    // The scheme follows the background OSC 11 reports: trve's, then bone's.
    const dark = try s.Stream.create(p, "test", .{ .colors = .{ .bg = .{ 0x00, 0x00, 0x00 } } }, .{ .write = true }, 0);
    defer dark.destroy();
    try p.feed("\x1b[?996n");
    try std.testing.expectEqualStrings("\x1b[?997;1n", p.input.items);
    p.input.clearRetainingCapacity();
    const light = try s.Stream.create(p, "test", .{ .colors = .{ .bg = .{ 0xf3, 0xf2, 0xf2 } } }, .{ .write = true }, 1001);
    defer light.destroy();
    try light.inputBytes("", 1001);
    try p.feed("\x1b[?996n");
    try std.testing.expectEqualStrings("\x1b[?997;2n", p.input.items);
}

test "a pane's cell size follows the active writer, then the latest" {
    const p = try s.Pane.create(a, "p0", .{ .cols = 80, .rows = 24 }, .{});
    defer p.destroy();
    try std.testing.expectEqual(@import("vt").Vt.CellSize{}, p.vt.cellSize());
    const first = try s.Stream.create(p, "test", .{ .cell = .{ .width = 9, .height = 18 } }, .{ .write = true }, 0);
    try p.feed("\x1b[16t\x1b[14t");
    try std.testing.expectEqualStrings("\x1b[6;18;9t\x1b[4;432;720t", p.input.items);
    // A watcher's cell size never counts.
    const watcher = try s.Stream.create(p, "test", .{ .cell = .{ .width = 1, .height = 1 } }, .{}, 1);
    defer watcher.destroy();
    const second = try s.Stream.create(p, "test", .{ .cell = .{ .width = 12, .height = 24 } }, .{ .write = true }, 2000);
    defer second.destroy();
    try std.testing.expectEqual(@import("vt").Vt.CellSize{ .width = 12, .height = 24 }, p.vt.cellSize());
    try first.inputBytes("", 4000);
    try std.testing.expectEqual(@import("vt").Vt.CellSize{ .width = 9, .height = 18 }, p.vt.cellSize());
    // The active writer leaves: the most recent writer's size remains.
    first.destroy();
    try std.testing.expectEqual(@import("vt").Vt.CellSize{ .width = 12, .height = 24 }, p.vt.cellSize());
}
