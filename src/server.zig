//! Adapter for venom-std's negotiated binary connections. CONTROL/NDJSON
//! delegates to the product dispatcher; pane streams share its socket.
const std = @import("std");
const proto = @import("proto");
const s = @import("stream.zig");
const Vt = @import("vt").Vt;
const Value = std.json.Value;
const Attachment = struct { conn: *proto.Connection, id: u32, stream: *s.Stream };
const Peer = struct { conn: *proto.Connection, high: u32 = 0, turn: u32 = 0 };
pub const Authorize = *const fn (?*anyopaque, *const proto.Connection, []const u8) s.Grants;

pub const Server = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    config: s.Config = .{},
    /// The theme's colours for programs that query OSC 10/11/12: a
    /// stream that sends no `colors` of its own gets these. Streams already
    /// attached keep what they were given.
    host_colors: ?Vt.QueryColors = null,
    panes: std.ArrayList(*s.Pane) = .empty,
    attachments: std.ArrayList(Attachment) = .empty,
    peers: std.ArrayList(Peer) = .empty,
    next_pane: u64 = 0,
    authorize: ?Authorize = null,
    auth_context: ?*anyopaque = null,
    control: ?proto.Handler = null,
    /// Runs for every closed connection before the control handler's own
    /// hook (connection-bound state).
    on_closed: ?struct { context: *anyopaque, f: *const fn (*anyopaque, *proto.Connection) void } = null,
    pub fn init(a: std.mem.Allocator, source: []const u8) Server {
        // source is the daemon's lifetime UUID identity, owned by its caller.
        return .{ .allocator = a, .source = source };
    }
    pub fn deinit(self: *Server) void {
        for (self.attachments.items) |a| a.stream.destroy();
        for (self.panes.items) |p| p.destroy();
        self.attachments.deinit(self.allocator);
        self.panes.deinit(self.allocator);
        self.peers.deinit(self.allocator);
    }
    pub fn handler(self: *Server) proto.Handler {
        return proto.Handler.init(self);
    }
    pub fn createPane(self: *Server, size: s.Size) !*s.Pane {
        const id = try std.fmt.allocPrint(self.allocator, "p{d}", .{self.next_pane});
        defer self.allocator.free(id);
        self.next_pane = try std.math.add(u64, self.next_pane, 1);
        const p = try s.Pane.create(self.allocator, id, size, self.config);
        errdefer p.destroy();
        try self.panes.append(self.allocator, p);
        return p;
    }
    pub fn removePane(self: *Server, p: *s.Pane) void {
        p.removed = true;
        // Close the master in the removal turn (hangs up the
        // terminal); the Vt and ring stay until streams have their CLOSE.
        if (p.pty) |*pty| pty.deinit();
        p.pty = null;
        // CLOSE follows any already-partially-written frame, through pump.
        for (self.attachments.items) |a| if (a.stream.pane == p) {
            a.stream.closed = true;
            a.stream.failure = "pane_removed";
        };
    }
    pub fn tick(self: *Server) anyerror!void {
        if (self.control) |h| if (h.tick) |f| try f(h.ptr);
    }
    pub fn allowFrame(_: *Server, conn: *const proto.Connection, kind: u16) bool {
        return conn.hasCap(s.capability) and kind >= s.Kind.attach and kind <= s.Kind.exit;
    }
    fn peer(self: *Server, conn: *proto.Connection) !*Peer {
        for (self.peers.items) |*p| if (p.conn == conn) return p;
        try self.peers.append(self.allocator, .{ .conn = conn });
        return &self.peers.items[self.peers.items.len - 1];
    }
    pub fn closed(self: *Server, conn: *proto.Connection) void {
        var i: usize = 0;
        while (i < self.attachments.items.len) {
            if (self.attachments.items[i].conn == conn) {
                self.attachments.orderedRemove(i).stream.destroy();
            } else i += 1;
        }
        for (self.peers.items, 0..) |p, j| if (p.conn == conn) {
            _ = self.peers.orderedRemove(j);
            break;
        };
        if (self.on_closed) |hook| hook.f(hook.context, conn);
        if (self.control) |h| h.vtable.closed(h.ptr, conn);
    }
    fn fail(self: *Server, conn: *proto.Connection, stream: u32, code: []const u8) !void {
        const bytes = try std.json.Stringify.valueAlloc(self.allocator, .{ .code = code, .message = code, .data = .{ .supported = [_][]const u8{ Vt.ghostty_format, "vt" } } }, .{});
        defer self.allocator.free(bytes);
        try conn.sendMessage(.{ .frame = .{ .kind = proto.Kind.err, .stream = stream, .payload = bytes } });
        if (stream == 0) conn.closing = true;
    }
    pub fn message(self: *Server, conn: *proto.Connection, msg: proto.Message) anyerror!void {
        if (msg == .ndjson) {
            if (self.control) |h| return h.vtable.message(h.ptr, conn, msg);
            // The embedding product supplies its schema dispatcher.
            return;
        }
        const f = msg.frame;
        if (!conn.hasCap(s.capability)) return self.fail(conn, 0, "protocol.bad_frame");
        const now = nowMs();
        var found: ?*s.Stream = null;
        for (self.attachments.items) |a| if (a.conn == conn and a.id == f.stream) {
            found = a.stream;
            break;
        };
        if (f.kind == s.Kind.attach) {
            const p = try self.peer(conn);
            if (f.stream == 0 or f.stream % 2 == 0 or f.stream <= p.high) return self.fail(conn, 0, "protocol.bad_frame");
            p.high = f.stream;
            const parsed = std.json.parseFromSlice(Value, self.allocator, f.payload, .{}) catch return self.fail(conn, f.stream, "invalid_params");
            defer parsed.deinit();
            const id = string(parsed.value, "pane") orelse return self.fail(conn, f.stream, "invalid_params");
            const grants = if (self.authorize) |auth| auth(self.auth_context, conn, id) else s.Grants{};
            if (!grants.read) return self.fail(conn, f.stream, "denied.read");
            var pane: ?*s.Pane = null;
            for (self.panes.items) |candidate| if (!candidate.removed and std.mem.eql(u8, id, candidate.id)) {
                pane = candidate;
                break;
            };
            const target = pane orelse return self.fail(conn, f.stream, "not_found.pane");
            var options = parseOptions(parsed.value, null) catch |err| return self.fail(conn, f.stream, parseCode(err));
            if (options.colors == null) options.colors = self.host_colors;
            const stream = s.Stream.create(target, self.source, options, grants, now) catch |err| return self.fail(conn, f.stream, if (err == error.DeniedRead) "denied.read" else "invalid_params");
            errdefer stream.destroy();
            try self.attachments.append(self.allocator, .{ .conn = conn, .id = f.stream, .stream = stream });
            return;
        }
        const stream = found orelse {
            const p = try self.peer(conn);
            return self.fail(conn, if (f.stream != 0 and f.stream % 2 == 1 and f.stream <= p.high) f.stream else 0, "protocol.bad_frame");
        };
        if (self.authorize) |auth| {
            stream.grants = auth(self.auth_context, conn, stream.pane.id);
            if (!stream.grants.read) {
                stream.failure = "denied.read";
                stream.closed = true;
            }
        }
        if (stream.closed) return;
        if (f.kind == proto.Kind.close or f.kind == proto.Kind.err) {
            stream.closed = true;
            return;
        }
        if (stream.phase == .attached) {
            stream.failure = "protocol.bad_frame";
            stream.closed = true;
            return;
        }
        switch (f.kind) {
            s.Kind.input => stream.inputBytes(f.payload, now) catch {
                stream.failure = "unavailable.input";
                stream.closed = true;
            },
            s.Kind.resize, s.Kind.resync => {
                if (f.kind == s.Kind.resync and stream.phase != .live) return;
                const parsed = std.json.parseFromSlice(Value, self.allocator, f.payload, .{}) catch {
                    stream.failure = "invalid_params";
                    stream.closed = true;
                    return;
                };
                defer parsed.deinit();
                if (f.kind == s.Kind.resize) {
                    const sz = parseSize(parsed.value) catch {
                        stream.failure = "invalid_params";
                        stream.closed = true;
                        return;
                    };
                    try stream.viewport(sz, now);
                } else {
                    var options = parseOptions(parsed.value, stream.options) catch |err| {
                        stream.failure = parseCode(err);
                        stream.closed = true;
                        return;
                    };
                    options.@"resume" = null;
                    if (field(parsed.value, "colors") != null and stream.grants.write) {
                        stream.pane.colors_seq += 1;
                        stream.colors_at = stream.pane.colors_seq;
                    }
                    if (field(parsed.value, "cell") != null and stream.grants.write) stream.noteCell();
                    stream.options = options;
                    try stream.viewport(options.size, now);
                    // Only INPUT and a frame that itself says
                    // claim: true make a writer active; the ATTACH value is not reused.
                    const claims = if (field(parsed.value, "claim")) |c| c == .bool and c.bool else false;
                    if (claims) try stream.pane.activity(stream, now);
                    try stream.pane.updateCell();
                    stream.requestResync();
                }
            },
            else => {
                stream.failure = "protocol.bad_frame";
                stream.closed = true;
            },
        }
    }
    /// Service panes regardless of socket readiness, then queue at most one
    /// frame per empty connection. Call around proto.Server.poll(0); the owner
    /// may poll PTY masters alongside the transport fd with its next deadline.
    pub fn pump(self: *Server, now: i64) !void {
        for (self.panes.items) |p| try p.service(now);
        for (self.peers.items) |*peer_state| {
            const conn = peer_state.conn;
            if (conn.closing or conn.output.items.len != 0) continue;
            // Round-robin streams, including idle ones, for split-pane peers.
            var chosen: ?usize = null;
            var fallback: ?usize = null;
            for (self.attachments.items, 0..) |a, i| {
                if (a.conn != conn or (a.stream.closed and a.stream.failure == null)) continue;
                if (fallback == null or a.id < self.attachments.items[fallback.?].id) fallback = i;
                if (a.id > peer_state.turn and (chosen == null or a.id < self.attachments.items[chosen.?].id)) chosen = i;
            }
            const start = chosen orelse fallback orelse continue;
            // Try every stream once; an idle first stream must not starve others.
            for (0..self.attachments.items.len) |delta| {
                const a = self.attachments.items[(start + delta) % self.attachments.items.len];
                if (a.conn != conn) continue;
                if (a.stream.failure) |code| if (std.mem.eql(u8, code, "pane_removed")) {
                    a.stream.failure = null;
                    try conn.sendMessage(.{ .frame = .{ .kind = proto.Kind.close, .stream = a.id, .payload = "{\"reason\":\"pane_removed\"}" } });
                    peer_state.turn = a.id;
                    break;
                };
                if (self.authorize) |auth| {
                    a.stream.grants = auth(self.auth_context, conn, a.stream.pane.id);
                    if (!a.stream.grants.read) {
                        a.stream.failure = "denied.read";
                        a.stream.closed = true;
                    }
                }
                const next_frame = a.stream.next(conn.max_frame, now) catch |err| blk: {
                    if (err == error.OutOfMemory) return err;
                    // A failed snapshot/stream cannot terminate other peers.
                    a.stream.failure = "internal.snapshot";
                    a.stream.closed = true;
                    break :blk try a.stream.next(conn.max_frame, now);
                };
                if (next_frame) |frame| {
                    defer frame.deinit(self.allocator);
                    try conn.sendMessage(.{ .frame = .{ .kind = frame.kind, .stream = a.id, .payload = frame.payload } });
                    peer_state.turn = a.id;
                    break;
                }
            }
        }
        // Closed attachments no longer retain snapshot buffers or affect size.
        var i: usize = 0;
        while (i < self.attachments.items.len) {
            const a = self.attachments.items[i];
            if (a.stream.closed and a.stream.failure == null) {
                self.attachments.orderedRemove(i).stream.destroy();
            } else i += 1;
        }
        i = 0;
        while (i < self.panes.items.len) {
            const p = self.panes.items[i];
            if (p.removed and p.streams.items.len == 0) {
                _ = self.panes.orderedRemove(i);
                p.destroy();
            } else i += 1;
        }
    }
};
pub fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) unreachable;
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(ts.nsec, 1000000);
}
fn field(v: Value, key: []const u8) ?Value {
    return if (v == .object) v.object.get(key) else null;
}
fn string(v: Value, key: []const u8) ?[]const u8 {
    const f = field(v, key) orelse return null;
    return if (f == .string) f.string else null;
}
fn uint(v: Value) !u64 {
    if (v != .integer or v.integer < 0 or v.integer > 9007199254740991) return error.InvalidParams;
    return @intCast(v.integer);
}
fn parseSize(v: Value) !s.Size {
    const cols = try uint(field(v, "cols") orelse return error.InvalidParams);
    const rows = try uint(field(v, "rows") orelse return error.InvalidParams);
    if (cols == 0 or rows == 0 or cols > 65535 or rows > 65535) return error.InvalidParams;
    return .{ .cols = @intCast(cols), .rows = @intCast(rows) };
}
fn parseCode(err: anyerror) []const u8 {
    return switch (err) {
        error.UnsupportedMode => "unsupported.mode",
        error.UnsupportedFormat => "unsupported.snapshot_format",
        else => "invalid_params",
    };
}
fn parseOptions(v: Value, current: ?s.Options) !s.Options {
    if (v != .object) return error.InvalidParams;
    var out = current orelse s.Options{};
    if (field(v, "mode")) |mode| {
        if (mode != .string) return error.InvalidParams;
        out.mode = std.meta.stringToEnum(s.Mode, mode.string) orelse return error.UnsupportedMode;
    } else if (current == null) return error.InvalidParams;
    if (field(v, "formats")) |formats| {
        if (formats != .array or formats.array.items.len == 0) return error.InvalidParams;
        var selected: ?s.Format = null;
        for (formats.array.items) |f| {
            if (f != .string) return error.InvalidParams;
            if (selected == null and std.mem.eql(u8, f.string, "vt")) selected = .vt;
            if (selected == null and out.mode != .raw and std.mem.eql(u8, f.string, Vt.ghostty_format)) selected = .ghostty;
        }
        out.format = selected orelse return error.UnsupportedFormat;
    } else if (current == null) return error.InvalidParams;
    if (out.mode == .raw and out.format != .vt) return error.UnsupportedFormat;
    if (field(v, "size")) |size| {
        out.size = try parseSize(size);
    } else if (current == null) return error.InvalidParams;
    if (field(v, "history")) |h| out.history = try uint(h);
    if (field(v, "claim")) |claim| {
        if (claim != .bool) return error.InvalidParams;
        out.claim = claim.bool;
    }
    if (field(v, "resume")) |r| {
        if (current != null) return error.InvalidParams;
        out.@"resume" = .{ .source = string(r, "source") orelse return error.InvalidParams, .offset = try uint(field(r, "offset") orelse return error.InvalidParams) };
    }
    if (field(v, "colors")) |colors| {
        if (colors != .object) return error.InvalidParams;
        var host: Vt.QueryColors = .{};
        inline for (.{ "fg", "bg", "cursor" }) |key| {
            if (field(colors, key)) |color| {
                if (color != .string or color.string.len != 7 or color.string[0] != '#') return error.InvalidParams;
                var rgb: [3]u8 = undefined;
                for (0..3) |i| rgb[i] = std.fmt.parseInt(u8, color.string[1 + 2 * i ..][0..2], 16) catch return error.InvalidParams;
                @field(host, key) = rgb;
            }
        }
        out.colors = host;
    }
    if (field(v, "cell")) |cell| {
        if (cell != .object) return error.InvalidParams;
        const w = try uint(field(cell, "width") orelse return error.InvalidParams);
        const h = try uint(field(cell, "height") orelse return error.InvalidParams);
        // 8.1: each at least 1. 4096 px is far past any real cell.
        if (w == 0 or h == 0 or w > 4096 or h > 4096) return error.InvalidParams;
        out.cell = .{ .width = @intCast(w), .height = @intCast(h) };
    }
    return out;
}

test "ATTACH.cell is parsed and checked" {
    const base = "{\"mode\":\"emulate\",\"formats\":[\"vt\"],\"size\":{\"cols\":80,\"rows\":24}";
    const good = try std.json.parseFromSlice(Value, std.testing.allocator, base ++ ",\"cell\":{\"width\":9,\"height\":18}}", .{});
    defer good.deinit();
    try std.testing.expectEqual(Vt.CellSize{ .width = 9, .height = 18 }, (try parseOptions(good.value, null)).cell.?);
    for ([_][]const u8{ "{\"width\":0,\"height\":18}", "{\"width\":9}", "{\"width\":9,\"height\":5000}", "[9,18]", "{\"width\":-1,\"height\":1}" }) |bad| {
        const json_text = try std.mem.concat(std.testing.allocator, u8, &.{ base, ",\"cell\":", bad, "}" });
        defer std.testing.allocator.free(json_text);
        const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, json_text, .{});
        defer parsed.deinit();
        try std.testing.expectError(error.InvalidParams, parseOptions(parsed.value, null));
    }
}
