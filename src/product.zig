//! Reactor-owned resources (sessions, windows, panes). Removed metadata remains as tombstones so
//! containment and ownership stay resolvable during retained event replay.
const std = @import("std");
const proto = @import("proto");
const g = proto.grants;
const streams = @import("server.zig");
const stream = @import("stream.zig");
const layout = @import("layout.zig");
const Pty = @import("pty.zig").Pty;
const Node = layout.Node;
const Observation = @import("observation.zig").Observation;
const supervisor = @import("supervisor");
const principal_events = @import("principal_events.zig");
const seam = @import("seam.zig");
const spawn_env = @import("spawn_env.zig");
const foreground = @import("foreground.zig");
const runs_mod = @import("run.zig");
const chrome = @import("chrome.zig");
const keys_registry = @import("keys_registry.zig");
const floats = @import("floats.zig");
extern "c" fn realpath(noalias [*:0]const u8, noalias [*]u8) ?[*:0]u8;
const capture_rows = @import("capture_rows.zig");
const Leader = supervisor.Leader;
const recovery = @import("recovery.zig");
const RequestId = supervisor.leaders.RequestId;
const Value = std.json.Value;
const eq = std.mem.eql;
// `sealed` counts in-flight recursive removals covering the resource.
/// `on_exit` (panes) and `on_empty` (sessions), fixed at creation.
pub const Policy = enum {
    keep,
    remove,
    pub fn param(c: *proto.Call, key: []const u8) Policy {
        const v = c.params.object.get(key) orelse return .keep;
        return if (v == .string and eq(u8, v.string, "remove")) .remove else .keep;
    }
};
pub const Session = struct { id: []const u8, name: []const u8, owner: g.Id, removed: bool = false, sealed: u32 = 0, on_empty: Policy = .keep };
pub const Window = struct { id: []const u8, name: []const u8, session: *Session, owner: g.Id, nodes: []Node, revision: u64 = 1, removed: bool = false, sealed: u32 = 0 };
/// `archive` marks a restored archive: no PTY, leader or principal.
/// The sampled foreground `process` and `title_current`.
pub const Foreground = struct {
    buf: [foreground.max_process]u8 = undefined,
    len: u16 = 0,
    pgid: std.c.pid_t = 0,
    sampled_ms: ?i64 = null,
    command_epoch: u64 = 0,
    title_current: bool = false,
    pub fn process(self: *const Foreground) ?[]const u8 {
        return if (self.len == 0) null else self.buf[0..self.len];
    }
    fn set(self: *Foreground, name: ?[]const u8) void {
        const n = name orelse "";
        @memcpy(self.buf[0..n.len], n);
        self.len = @intCast(n.len);
    }
};
pub const Pane = struct { id: []const u8, window: *Window, owner: g.Id, principal: g.Id, pane: *stream.Pane, archive: ?*recovery.Archive = null, removed: bool = false, observation: Observation, title: []const u8 = "", argv0: ?[]const u8 = null, fg: Foreground = .{}, last_output: u64 = 0, exit_published: bool = false, leader: ?*Leader = null, sealed: u32 = 0, stuck: bool = false, escalated: bool = false, run: ?*runs_mod.Run = null, on_exit: Policy = .keep, tags: chrome.Tags = .{}, tags_revision: u64 = 0, attention: chrome.Attention = .{}, layer: floats.Layer = .tile, float: ?*floats.Float = null };

/// A termination request answered on a later reactor turn, by ticket.
const Op = struct {
    ticket: proto.Ticket,
    dispatcher: *proto.Dispatcher,
    kind: enum { kill, cancel, window, session },
    remove: bool = false,
    /// pane.kill only: the leader had already exited; nothing was signalled.
    already: bool = false,
    session: ?*Session = null,
    /// The removal subtree in ascending ID order; sealed while in flight.
    windows: []*Window,
    panes: []*Pane,
    /// Pending Leaders requests, parallel to `panes`.
    requests: []?RequestId,
    timed_out: bool = false,
};

/// Stage a sequence of events with final wire sequence numbers, reserve the
/// destination, then transfer their allocations at the resource commit point.
pub const Batch = struct {
    staged: proto.events.Log,
    destination: *proto.events.Log,
    pub fn init(log: *proto.events.Log) !Batch {
        return .{ .destination = log, .staged = .{ .gpa = log.gpa, .source = try log.gpa.dupe(u8, log.source), .limits = log.limits, .snapshot = null, .catalog = log.catalog, .high = log.high } };
    }
    pub fn deinit(self: *Batch) void {
        self.staged.deinit();
    }
    pub fn append(self: *Batch, resource: []const u8, kind: []const u8, data: anytype) !void {
        if (self.staged.high == proto.events.max_seq) return error.Overflow;
        try self.staged.append(resource, kind, data);
    }
    pub fn reserve(self: *Batch) !void {
        try self.destination.entries.ensureUnusedCapacity(self.destination.gpa, self.staged.entries.items.len - self.staged.head);
    }
    pub fn commit(self: *Batch) void {
        const dest = self.destination;
        dest.entries.appendSliceAssumeCapacity(self.staged.entries.items[self.staged.head..]);
        dest.used += self.staged.used;
        dest.high = self.staged.high;
        self.staged.entries.items.len = 0;
        self.staged.used = 0;
        dest.trim(streams.nowMs());
    }
};
/// `pane.capture_rows` doctor counters. Never text, ranges or pane contents.
pub const RowsStats = struct {
    calls: u64 = 0,
    partial: u64 = 0,
    denied: u64 = 0,
    missing: u64 = 0,
    params: u64 = 0,
    evicted: u64 = 0,
    future: u64 = 0,
    epoch: u64 = 0,
    size: u64 = 0,
    max_hold_us: i64 = 0,
    fn hold(self: *RowsStats, us: i64) void {
        self.max_hold_us = @max(self.max_hold_us, us);
    }
    fn failed(self: *RowsStats, f: capture_rows.Failure) void {
        switch (f) {
            .params => self.params += 1,
            .rows => |d| if (d.reason[0] == 'e') {
                self.evicted += 1;
            } else {
                self.future += 1;
            },
            .epoch => self.epoch += 1,
            .size => self.size += 1,
        }
    }
};
pub const Product = struct {
    a: std.mem.Allocator,
    streams: *streams.Server,
    registry: *g.Registry,
    events: *proto.events.Log,
    /// Principal lifecycle event emitter, when the daemon runs one.
    principals: ?*principal_events.Emitter = null,
    environ: std.process.Environ,
    socket: []const u8 = "",
    sessions: std.ArrayList(*Session) = .empty,
    windows: std.ArrayList(*Window) = .empty,
    panes: std.ArrayList(*Pane) = .empty,
    next_session: u64 = 0,
    next_window: u64 = 0,
    shutting_down: bool = false,
    /// Latched daemon lifetime and on-demand state machine.
    lifecycle: @import("lifecycle.zig").State = .{},
    /// `attention.*` config; the daemon reads `from_bell`.
    attention: chrome.AttentionConfig = .{},
    /// The sole waiter for pane leaders.
    leaders: *supervisor.Leaders,
    ops: std.ArrayList(*Op) = .empty,
    /// Leaders of failed spawns, released once reaped.
    discarded: std.ArrayList(*Leader) = .empty,
    /// Doctor counters.
    kills: u64 = 0,
    escalations: u64 = 0,
    timeouts: u64 = 0,
    discarded_input: u64 = 0,
    /// The supervisor's count of escaped descendants; null outside `serve`.
    orphans_reaped: ?*const std.atomic.Value(u64) = null,
    records_low: u64 = 0,
    /// Base spawn environment, captured on first use.
    base: ?spawn_env.Base = null,
    /// Spawn environment doctor counters, indexed like spawn_env's reason lists.
    env_failures: [spawn_env.env_reasons.len]u64 = @splat(0),
    cwd_not_found: u64 = 0,
    cwd_failures: [spawn_env.cwd_reasons.len]u64 = @splat(0),
    spawn_failures: [spawn_env.spawn_reasons.len]u64 = @splat(0),
    rows_stats: RowsStats = .{},
    /// Trusted run records, keys and waiters.
    runs: runs_mod.Runs = .{},
    /// Status segments and notifications.
    chrome: chrome.Chrome = .{},
    /// Registered key tables.
    keytables: keys_registry.Registry = .{},
    /// Float presets, popup tickets and clients.
    floats: floats.State = .{},
    pub fn deinit(self: *Product) void {
        self.floats.deinit(self.a);
        self.keytables.deinit(self.a);
        self.chrome.deinit(self.a);
        self.runs.deinit(self.a);
        if (self.base) |*b| b.deinit(self.a);
        for (self.ops.items) |op| self.freeOp(op);
        self.ops.deinit(self.a);
        self.discarded.deinit(self.a);
        for (self.panes.items) |p| {
            if (p.archive) |x| x.destroy(self.a);
            p.observation.deinit();
            if (p.title.len != 0) self.a.free(p.title);
            if (p.argv0) |x| self.a.free(x);
            p.tags.deinit(self.a);
            p.attention.deinit(self.a);
            if (p.float) |f| f.destroy(self.a);
            self.a.free(p.id);
            self.a.destroy(p);
        }
        for (self.windows.items) |w| {
            self.a.free(w.nodes);
            self.a.free(w.id);
            self.a.free(w.name);
            self.a.destroy(w);
        }
        for (self.sessions.items) |s| {
            self.a.free(s.id);
            self.a.free(s.name);
            self.a.destroy(s);
        }
        self.panes.deinit(self.a);
        self.windows.deinit(self.a);
        self.sessions.deinit(self.a);
    }
    const verb_count = @import("manifest.zig").product.len;
    pub fn bindings(self: *Product) [verb_count]proto.Binding {
        var out: [verb_count]proto.Binding = undefined;
        for (@import("manifest.zig").product, &out) |v, *b| b.* = .{ .verb = v.name, .handler = proto.VerbHandler.init(self) };
        return out;
    }
    pub fn parentOf(self: *Product, resource: g.Resource) ?g.Resource {
        if (eq(u8, resource.kind, "session")) return .{ .kind = "server", .id = "root" };
        if (eq(u8, resource.kind, "window")) for (self.windows.items) |w| {
            if (eq(u8, w.id, resource.id)) return .{ .kind = "session", .id = w.session.id };
        };
        if (eq(u8, resource.kind, "pane")) for (self.panes.items) |p| {
            if (eq(u8, p.id, resource.id)) return .{ .kind = "window", .id = p.window.id };
        };
        // parentOf(run:<id>) = pane:<pane>, frozen after removal.
        if (eq(u8, resource.kind, "run")) if (self.runs.resolve(resource.id)) |r| return .{ .kind = "pane", .id = r.pane };
        return self.chrome.parentOf(resource);
    }
    pub fn ownerOf(self: *Product, resource: g.Resource) ?g.Id {
        if (eq(u8, resource.kind, "server")) return g.owner;
        if (eq(u8, resource.kind, "session")) for (self.sessions.items) |s| {
            if (eq(u8, s.id, resource.id)) return s.owner;
        };
        if (eq(u8, resource.kind, "window")) for (self.windows.items) |w| {
            if (eq(u8, w.id, resource.id)) return w.owner;
        };
        if (eq(u8, resource.kind, "pane")) for (self.panes.items) |p| {
            if (eq(u8, p.id, resource.id)) return p.owner;
        };
        if (eq(u8, resource.kind, "run")) if (self.runs.resolve(resource.id)) |r| return r.owner;
        return null;
    }
    pub fn streamGrants(ctx: ?*anyopaque, conn: *const proto.Connection, id: []const u8) stream.Grants {
        const self: *Product = @ptrCast(@alignCast(ctx.?));
        const r: g.Resource = .{ .kind = "pane", .id = id };
        return .{ .read = self.registry.allows(conn.identity, .read, r, g.nowSeconds()), .write = !self.shutting_down and self.registry.allows(conn.identity, .write, r, g.nowSeconds()) };
    }
    pub fn session(self: *Product, id: []const u8) ?*Session {
        for (self.sessions.items) |s| if (!s.removed and eq(u8, s.id, id)) return s;
        return null;
    }
    fn window(self: *Product, id: []const u8) ?*Window {
        for (self.windows.items) |w| if (!w.removed and eq(u8, w.id, id)) return w;
        return null;
    }
    pub fn pane(self: *Product, id: []const u8) ?*Pane {
        for (self.panes.items) |p| if (!p.removed and eq(u8, p.id, id)) return p;
        return null;
    }
    fn allowed(self: *Product, c: *proto.Call, kind: []const u8, id: []const u8) bool {
        return self.registry.allows(c.conn.identity, .read, .{ .kind = kind, .id = id }, g.nowSeconds());
    }
    pub fn allocateId(self: *Product, prefix: u8, counter: *u64) ![]const u8 {
        if (counter.* == std.math.maxInt(u64)) return error.Overflow;
        const n = counter.*;
        counter.* += 1;
        return std.fmt.allocPrint(self.a, "{c}{d}", .{ prefix, n });
    }
    pub fn resourceName(a: std.mem.Allocator, kind: []const u8, identifier: []const u8) ![]const u8 {
        return std.fmt.allocPrint(a, "{s}:{s}", .{ kind, identifier });
    }
    fn text(c: *proto.Call, key: []const u8) []const u8 {
        return c.params.object.get(key).?.string;
    }
    fn fail(c: *proto.Call, code: []const u8) !void {
        return c.fail(code, code, struct {}{});
    }
    fn result(c: *proto.Call, value: anytype) !void {
        const bytes = try std.json.Stringify.valueAlloc(c.arena(), value, .{ .emit_null_optional_fields = false });
        if (bytes.len + c.id_json.len + 16 > c.conn.max_frame) return fail(c, "unsupported.result_size");
        try c.ok(try std.json.parseFromSliceLeaky(Value, c.arena(), bytes, .{}));
    }
    /// Also the CLI launcher's pre-launch check.
    pub fn nameValid(name: []const u8) bool {
        if (name.len > 128 or !std.unicode.utf8ValidateSlice(name)) return false;
        for (name) |ch| if (ch < 32 or ch == 127) return false;
        return true;
    }
    fn windowValue(w: *Window) @TypeOf(.{ .window = w.id, .session = w.session.id, .name = w.name, .revision = w.revision, .nodes = w.nodes }) {
        std.debug.assert(layout.valid(w.nodes));
        return .{ .window = w.id, .session = w.session.id, .name = w.name, .revision = w.revision, .nodes = w.nodes };
    }
    pub fn call(self: *Product, c: *proto.Call) anyerror!void {
        const dispatcher = c.dispatcher;
        const ticket = c.ticket;
        self.dispatch(c) catch |err| switch (err) {
            error.OutOfMemory, error.Overflow => if (dispatcher.get(ticket)) |open| try fail(open, "internal"),
            else => return err,
        };
    }
    fn dispatch(self: *Product, c: *proto.Call) !void {
        const verb = c.verb.name;
        const a = c.arena();
        // The new destructive forms authorize before reporting shutdown.
        const deferred = eq(u8, verb, "pane.kill") or ((eq(u8, verb, "window.remove") or eq(u8, verb, "session.remove")) and flag(c, "recursive"));
        if (self.shutting_down and c.verb.grant != .read and !deferred) return fail(c, "unavailable.shutdown");
        if (eq(u8, verb, "run") or std.mem.startsWith(u8, verb, "run.")) return runs_mod.call(self, c);
        if (std.mem.startsWith(u8, verb, "status.") or std.mem.startsWith(u8, verb, "notify.")) return chrome.call(self, c);
        if (std.mem.startsWith(u8, verb, "keys.")) return keys_registry.call(self, c);
        if (eq(u8, verb, "pane.float") or eq(u8, verb, "pane.popup") or eq(u8, verb, "popup.ticket") or eq(u8, verb, "floats.register")) return floats.call(self, c);
        if (eq(u8, verb, "session.create")) {
            const conn = c.conn;
            if (!try self.admit(c, .write, .{ .kind = "server", .id = "root" })) return;
            const name = text(c, "name");
            if (!nameValid(name)) return c.fail("invalid_params.name", "invalid display name", .{ .param = "name" });
            var committed = false;
            const s = try self.a.create(Session);
            defer if (!committed) self.a.destroy(s);
            const sid = try self.allocateId('s', &self.next_session);
            defer if (!committed) self.a.free(sid);
            const owned_name = try self.a.dupe(u8, name);
            defer if (!committed) self.a.free(owned_name);
            s.* = .{ .id = sid, .name = owned_name, .owner = c.conn.identity.principal, .on_empty = Policy.param(c, "on_empty") };
            try self.sessions.ensureUnusedCapacity(self.a, 1);
            var batch = try Batch.init(self.events);
            defer batch.deinit();
            try batch.append(try resourceName(a, "session", sid), "session.created", .{ .session = sid, .name = name });
            try batch.reserve();
            try result(c, .{ .session = sid, .name = owned_name });
            self.sessions.appendAssumeCapacity(s);
            batch.commit();
            committed = true;
            self.lifecycle.created();
            seam.createCommitted(conn);
            return;
        }
        if (eq(u8, verb, "session.list")) {
            var out: std.ArrayList(Value) = .empty;
            for (self.sessions.items) |s| if (!s.removed and self.allowed(c, "session", s.id)) try out.append(a, try jsonValue(a, .{ .session = s.id, .name = s.name }));
            return result(c, .{ .sessions = out.items });
        }
        if (eq(u8, verb, "session.get") or eq(u8, verb, "session.remove") or eq(u8, verb, "window.create")) {
            const sid = text(c, "session");
            if (!try self.admit(c, c.verb.grant, .{ .kind = "session", .id = sid })) return;
            const s = self.session(sid) orelse return fail(c, "not_found.session");
            if (eq(u8, verb, "window.create")) {
                if (s.sealed > 0) return fail(c, "conflict.removing");
                // With a matching `near`, split that pane instead.
                switch (try floats.nearSource(self, c, s)) {
                    .answered => return,
                    .pane => |near| {
                        var place: floats.Place = .{ .axis = floats.autoAxis(near) };
                        return self.spawnWith(c, s, near, null, null, &place);
                    },
                    .none => {},
                }
                return self.spawn(c, s, null, null, null);
            }
            if (eq(u8, verb, "session.remove") and flag(c, "recursive")) return self.removeTree(c, s, null);
            var out: std.ArrayList(Value) = .empty;
            for (self.windows.items) |w| if (!w.removed and w.session == s) try out.append(a, try jsonValue(a, .{ .window = w.id, .name = w.name }));
            if (eq(u8, verb, "session.get")) return result(c, .{ .session = sid, .name = s.name, .windows = out.items });
            if (s.sealed > 0) return fail(c, "conflict.removing");
            if (out.items.len != 0) return fail(c, "conflict.not_empty");
            return self.commitRemoval(c, null, &.{}, s, struct {}{});
        }
        if (eq(u8, verb, "window.get") or eq(u8, verb, "window.remove")) {
            const wid = text(c, "window");
            if (!try self.admit(c, c.verb.grant, .{ .kind = "window", .id = wid })) return;
            const w = self.window(wid) orelse return fail(c, "not_found.window");
            if (eq(u8, verb, "window.get")) {
                const v = windowValue(w);
                return result(c, .{ .window = v.window, .session = v.session, .name = v.name, .revision = v.revision, .nodes = v.nodes, .floats = try floats.windowFloats(a, self, w) });
            }
            if (flag(c, "recursive")) return self.removeTree(c, null, w);
            if (w.sealed > 0) return fail(c, "conflict.removing");
            if (w.nodes.len != 0 or self.windowHasPanes(w)) return fail(c, "conflict.not_empty");
            var one = [_]*Window{w};
            return self.commitRemoval(c, null, &one, null, struct {}{});
        }
        if (eq(u8, verb, "pane.list")) {
            const sid = if (c.params.object.get("session")) |v| v.string else null;
            if (sid) |s| {
                if (!try c.authorize(.read, .{ .kind = "session", .id = s })) return;
                if (self.session(s) == null) return fail(c, "not_found.session");
            }
            var out: std.ArrayList(Value) = .empty;
            for (self.panes.items) |p| if (!p.removed and (sid == null or eq(u8, sid.?, p.window.session.id)) and self.allowed(c, "pane", p.id)) try out.append(a, try jsonValue(a, .{ .pane = p.id, .window = p.window.id, .session = p.window.session.id, .title = p.title, .argv0 = p.argv0, .process = p.fg.process(), .title_current = if (p.pane.status == null) @as(?bool, p.fg.title_current) else null, .exited = p.pane.status != null, .recovery = recovery.metadata(p), .tags = p.tags.items.items, .attention = @tagName(p.attention.level), .layer = @tagName(p.layer), .pid = if (self.liveRoot(p)) |r| r.pid else null, .start = if (self.liveRoot(p)) |r| r.start else null }));
            return result(c, .{ .panes = out.items });
        }
        const pid = text(c, "pane");
        const rows_verb = eq(u8, verb, "pane.capture_rows");
        if (rows_verb) self.rows_stats.calls += 1;
        if (!try self.admit(c, c.verb.grant, .{ .kind = "pane", .id = pid })) {
            if (rows_verb) self.rows_stats.denied += 1;
            return;
        }
        const relaunch = eq(u8, verb, "pane.relaunch");
        if (relaunch) {
            // The scoped write check precedes archive lookup.
            if (!try c.authorize(.write, .{ .kind = "pane", .id = pid })) return;
            if (!flag(c, "ack_orphans")) return c.fail("invalid_params.ack_orphans", "ack_orphans must be true", .{ .param = "ack_orphans" });
        }
        const p = self.pane(pid) orelse {
            if (rows_verb) self.rows_stats.missing += 1;
            return fail(c, "not_found.pane");
        };
        if (rows_verb) return self.captureRows(c, p);
        if (eq(u8, verb, "pane.tag")) return chrome.paneTag(self, c, p);
        if (eq(u8, verb, "pane.attention")) return chrome.paneAttention(self, c, p);
        if (eq(u8, verb, "pane.place")) return floats.panePlace(self, c, p);
        if (eq(u8, verb, "pane.raise")) return floats.paneRaise(self, c, p);
        if (eq(u8, verb, "pane.resize")) return self.paneResize(c, p);
        if (relaunch) {
            if (p.archive == null) return fail(c, "conflict.not_archive");
            if (p.sealed > 0 or p.window.sealed > 0 or p.window.session.sealed > 0) return fail(c, "conflict.removing");
            return self.spawn(c, p.window.session, null, null, p);
        }
        if (eq(u8, verb, "pane.kill")) return self.kill(c, p, .kill);
        if (eq(u8, verb, "pane.split")) {
            if (p.sealed > 0) return fail(c, "conflict.removing");
            if (p.pane.terminating) return fail(c, "conflict.pane_terminating");
            if (p.pane.status != null) return fail(c, "conflict.pane_exited");
            if (p.layer != .tile) return c.fail("conflict.layer", "only tiled panes split; place the float first", .{ .layer = @tagName(p.layer) });
            // `near` picks the largest matching pane instead.
            const source = switch (try floats.nearSource(self, c, p.window.session)) {
                .answered => return,
                .pane => |near| near,
                .none => p,
            };
            return self.spawn(c, p.window.session, source, null, null);
        }
        if (eq(u8, verb, "pane.send")) {
            if (p.pane.terminating) return fail(c, "conflict.pane_terminating");
            if (p.pane.status != null) return fail(c, "conflict.pane_exited");
            const bytes = text(c, "text");
            p.pane.queueInput(bytes) catch |err| {
                if (err == error.OutOfMemory) return err;
                return fail(c, "unavailable.input");
            };
            return result(c, .{ .bytes = bytes.len });
        }
        if (eq(u8, verb, "pane.capture")) {
            const vt = p.pane.vt;
            const rows = vt.rows();
            const size = vt.size();
            if (@as(usize, size.cols) * size.rows > c.conn.max_frame) return fail(c, "unsupported.result_size");
            const bytes = try vt.exportRows(a, rows.epoch, rows.active, rows.end);
            const status = p.pane.status;
            return result(c, .{ .text = bytes[0 .. bytes.len - 1], .cols = size.cols, .rows = size.rows, .exited = status != null, .exit_code = if (status != null and status.? == .code) @as(?u8, status.?.code) else null, .signal = if (status != null and status.? == .signal) status.?.signal else null, .recovery = recovery.metadata(p) });
        }
        if (p.sealed > 0) return fail(c, "conflict.removing");
        if (p.pane.status == null) return fail(c, "conflict.pane_running");
        return self.commitRemoval(c, p, &.{}, null, struct {}{});
    }
    /// Authorization precedes the stopping rejection, so an
    /// unknown caller still receives denied.*; authorized mutations after the
    /// final removal fail unavailable.shutdown without effects.
    /// A leaf's cells for `layout`: the size its PTY has now.
    pub const PaneSizes = struct {
        product: *Product,
        pub fn extent(ctx: @This(), id: []const u8, on: layout.Axis) u32 {
            const leaf = ctx.product.pane(id) orelse return 1;
            const size = leaf.pane.vt.size();
            return if (on == .cols) size.cols else size.rows;
        }
    };
    /// `pane.resize`. Split ratios are shared state of the window, so this
    /// needs write on the window, like `pane.raise`.
    fn paneResize(self: *Product, c: *proto.Call, p: *Pane) !void {
        const w = p.window;
        if (!try c.authorize(.write, .{ .kind = "window", .id = w.id })) return;
        if (p.sealed > 0 or w.sealed > 0 or w.session.sealed > 0) return fail(c, "conflict.removing");
        if (p.layer != .tile) return c.fail("conflict.layer", "only tiled panes have a split to resize", .{ .layer = @tagName(p.layer) });
        const direction = text(c, "direction");
        const axis: layout.Axis = if (eq(u8, direction, "left") or eq(u8, direction, "right")) .cols else .rows;
        const cells = c.params.object.get("cells").?.integer;
        const delta = if (eq(u8, direction, "left") or eq(u8, direction, "up")) -cells else cells;
        const move = layout.moveDivider(w.nodes, p.id, axis, delta, PaneSizes{ .product = self }) orelse return result(c, .{ .window = w.id, .revision = w.revision, .moved = @as(u32, 0) });
        const nodes = try self.a.dupe(Node, w.nodes);
        var keep = false;
        defer if (!keep) self.a.free(nodes);
        nodes[move.split].ratio = move.ratio;
        var batch = try Batch.init(self.events);
        defer batch.deinit();
        try batch.append(try resourceName(c.arena(), "window", w.id), "window.layout_changed", .{ .window = w.id, .session = w.session.id, .revision = w.revision + 1, .nodes = nodes });
        try batch.reserve();
        try result(c, .{ .window = w.id, .revision = w.revision + 1, .moved = move.moved });
        keep = true;
        self.a.free(w.nodes);
        w.nodes = nodes;
        w.revision += 1;
        batch.commit();
    }
    pub fn admit(self: *Product, c: *proto.Call, grant: proto.schema.Grant, resource: g.Resource) !bool {
        if (!try c.authorize(grant, resource)) return false;
        if (grant != .read and self.lifecycle.stopping()) {
            try fail(c, "unavailable.shutdown");
            return false;
        }
        return true;
    }
    pub fn liveSessions(self: *const Product) usize {
        var n: usize = 0;
        for (self.sessions.items) |s| if (!s.removed) {
            n += 1;
        };
        return n;
    }
    /// One bounded page, read between two `Vt.feed` calls.
    fn captureRows(self: *Product, c: *proto.Call, p: *Pane) !void {
        const params = c.params.object;
        const opt = struct {
            fn get(o: std.json.ObjectMap, key: []const u8) ?u64 {
                return if (o.get(key)) |v| @intCast(v.integer) else null;
            }
        }.get;
        const req: capture_rows.Request = .{ .tail = opt(params, "tail"), .epoch = opt(params, "epoch"), .start = opt(params, "start"), .end = opt(params, "end"), .max_rows = opt(params, "max_rows") orelse capture_rows.default_max_rows, .max_bytes = opt(params, "max_bytes") orelse capture_rows.default_max_bytes };
        // The response line is `{"id":<id>,"ok":<result>}` plus LF.
        const envelope = c.id_json.len + 14;
        const budget: u64 = if (c.conn.max_frame > envelope) c.conn.max_frame - envelope else 0;
        const began = stream.nowUs();
        const outcome = try capture_rows.read(c.arena(), p.pane.vt, p.id, p.pane.ring.head, req, budget);
        self.rows_stats.hold(stream.nowUs() - began);
        switch (outcome) {
            .page => |page| {
                if (!page.done) self.rows_stats.partial += 1;
                return c.ok(page);
            },
            .failure => |f| {
                self.rows_stats.failed(f);
                return switch (f) {
                    .params => |d| c.fail(f.code(), switch (d.reason[0]) {
                        'e' => if (d.reason[1] == 'x') "tail cannot be combined with epoch, start or end" else "start and end require epoch",
                        else => "end is before start",
                    }, d),
                    .rows => |d| c.fail(f.code(), if (d.reason[0] == 'e')
                        try std.fmt.allocPrint(c.arena(), "rows {d} to {d} are no longer retained", .{ d.first, d.last })
                    else
                        try std.fmt.allocPrint(c.arena(), "rows {d} to {d} do not exist yet", .{ d.first, d.last }), .{ .reason = d.reason, .screen = d.screen, .epoch = d.epoch, .oldest = d.oldest, .end = d.end }),
                    .epoch => |d| c.fail(f.code(), try std.fmt.allocPrint(c.arena(), "row epoch {d} is no longer current", .{d.given}), d.state),
                    .size => |d| c.fail(f.code(), "the first selected row does not fit max_bytes or max_frame", d),
                };
            },
        }
    }
    fn flag(c: *proto.Call, key: []const u8) bool {
        return if (c.params.object.get(key)) |v| v == .bool and v.bool else false;
    }
    fn signalParam(c: *proto.Call) []const u8 {
        return if (c.params.object.get("signal")) |v| v.string else "SIGHUP";
    }
    fn deadlineParam(self: *Product, c: *proto.Call) i64 {
        const grace = if (c.params.object.get("grace_ms")) |v| v.integer else 2000;
        return self.leaders.now() + grace;
    }
    fn posixSignal(name: []const u8) std.posix.SIG {
        if (eq(u8, name, "SIGTERM")) return .TERM;
        if (eq(u8, name, "SIGINT")) return .INT;
        return .HUP;
    }

    /// The removal commit in one turn: either a
    /// single exited pane, or whole windows (and a session). Every fallible
    /// step precedes the response and every effect.
    fn commitRemoval(self: *Product, c: *proto.Call, single: ?*Pane, windows: []const *Window, session_: ?*Session, value: anytype) !void {
        const a = c.arena();
        var committed = false;
        var batch = try Batch.init(self.events);
        defer batch.deinit();
        var nodes: ?[]Node = null;
        defer if (!committed) if (nodes) |n| self.a.free(n);
        if (single) |p| {
            const w = p.window;
            try self.paneRemovalEvents(&batch, a, p);
            // Floats and popups are not in the split tree.
            if (p.layer == .tile) {
                if (w.revision == proto.events.max_seq) return error.Overflow;
                nodes = try layout.edit(self.a, w.nodes, p.id, null);
                try batch.append(try resourceName(a, "window", w.id), "window.layout_changed", .{ .window = w.id, .session = w.session.id, .revision = w.revision + 1, .nodes = nodes.? });
            }
        } else {
            for (windows) |w| if (!w.removed) {
                for (self.panes.items) |p| if (!p.removed and p.window == w) try self.paneRemovalEvents(&batch, a, p);
                try batch.append(try resourceName(a, "window", w.id), "window.removed", .{ .window = w.id, .session = w.session.id });
            };
            if (session_) |s| try batch.append(try resourceName(a, "session", s.id), "session.removed", .{ .session = s.id });
        }
        // Not the call arena: answering the call frees it.
        var retired: std.ArrayList(*Pane) = .empty;
        defer retired.deinit(self.a);
        if (single) |p| try retired.append(self.a, p) else for (windows) |w| if (!w.removed) {
            for (self.panes.items) |p| if (!p.removed and p.window == w) try retired.append(self.a, p);
        };
        try batch.reserve();
        try result(c, value);
        // The response is queued; from here nothing fails.
        if (single) |p| if (nodes) |n| {
            const w = p.window;
            self.a.free(w.nodes);
            w.nodes = n;
            w.revision += 1;
        };
        for (retired.items) |p| self.retirePane(p);
        if (single == null) for (windows) |w| {
            w.removed = true;
        };
        if (session_) |s| s.removed = true;
        batch.commit();
        committed = true;
        // The final removal latches stopping in this same reactor turn.
        if (session_ != null) self.lifecycle.removed(self.liveSessions());
        // Archives have no principal of their own.
        for (retired.items) |p| if (p.archive == null) self.registry.revoke(.{ .principal = g.owner }, p.principal, g.nowSeconds()) catch {};
    }
    fn paneRemovalEvents(_: *Product, batch: *Batch, a: std.mem.Allocator, p: *Pane) !void {
        if (p.observation.records.len > 0) try batch.append(try resourceName(a, "pane", p.id), "program.status_changed", .{ .pane = p.id, .reason = "pane_removed", .records = p.observation.records[0..0] });
        try batch.append(try resourceName(a, "pane", p.id), "pane.removed", .{ .pane = p.id });
    }
    /// Closes the PTY master, queues CLOSE on streams and forgets the leader.
    fn retirePane(self: *Product, p: *Pane) void {
        p.removed = true;
        self.discarded_input += p.pane.discarded_input;
        self.streams.removePane(p.pane);
        if (p.leader) |l| self.leaders.release(l) catch {};
        p.leader = null;
    }

    /// `pane.kill`, or `run.cancel` of the run's pane.
    pub fn kill(self: *Product, c: *proto.Call, p: *Pane, kind: enum { kill, cancel }) !void {
        if (self.shutting_down) return fail(c, "unavailable.shutdown");
        const remove = flag(c, "remove");
        const cancel = kind == .cancel;
        if (remove and p.sealed > 0) return fail(c, "conflict.removing");
        if (p.pane.status != null and !p.exit_published) try self.publishExit(p);
        if (p.pane.status != null) return self.finishKill(c, p, false, remove, cancel);
        try self.ops.ensureUnusedCapacity(self.a, 1);
        var one = [_]*Pane{p};
        const op = try self.newOp(c, if (cancel) .cancel else .kill, &.{}, &one, null);
        errdefer self.freeOp(op);
        op.remove = remove;
        const name = signalParam(c);
        const starts = !p.pane.terminating;
        var batch = try Batch.init(self.events);
        defer batch.deinit();
        const cause: runs_mod.Cause = if (cancel) .cancel else .pane_kill;
        if (starts) {
            try self.terminatingEvents(&batch, c.arena(), p, name, cause);
            try batch.reserve();
        }
        switch (try self.leaders.terminate(p.leader.?, .{ .signal = posixSignal(name), .deadline = self.deadlineParam(c) })) {
            .already_exited => op.already = true,
            .started => |id| {
                op.requests[0] = id;
                self.startedTerminating(p, cause);
                batch.commit();
            },
            .joined => |id| op.requests[0] = id,
        }
        self.ops.appendAssumeCapacity(op);
    }
    fn startedTerminating(self: *Product, p: *Pane, cause: runs_mod.Cause) void {
        p.pane.freezeInput();
        self.kills += 1;
        if (p.run) |r| self.runs.terminating(r, cause);
    }
    /// `pane.terminating`, then `run.terminating` when the
    /// pane's run is still running (its first cause wins).
    fn terminatingEvents(_: *Product, batch: *Batch, a: std.mem.Allocator, p: *Pane, name: []const u8, cause: runs_mod.Cause) !void {
        try batch.append(try resourceName(a, "pane", p.id), "pane.terminating", .{ .pane = p.id, .requested_signal = name });
        if (p.run) |r| if (r.state == .running) try batch.append(try resourceName(a, "run", r.id), "run.terminating", .{ .run = r.id, .cause = @tagName(cause) });
    }
    fn finishKill(self: *Product, c: *proto.Call, p: *Pane, terminated: bool, remove: bool, cancel: bool) !void {
        if (cancel) return runs_mod.respondRecord(self, c, p.run.?);
        const status = p.pane.status.?;
        const value = .{
            .pane = p.id,
            .outcome = if (terminated) "terminated" else "already_exited",
            .removed = remove,
            .escalated = terminated and p.escalated,
            .exit_code = if (status == .code) @as(?u8, status.code) else null,
            .signal = if (status == .signal) @as(?[]const u8, status.signal) else null,
        };
        if (!remove or p.removed) return result(c, value);
        return self.commitRemoval(c, p, &.{}, null, value);
    }

    /// Recursive window/session removal, first turn.
    fn removeTree(self: *Product, c: *proto.Call, s_: ?*Session, w_: ?*Window) !void {
        if (self.shutting_down) return fail(c, "unavailable.shutdown");
        const a = c.arena();
        const now_s = g.nowSeconds();
        var windows: std.ArrayList(*Window) = .empty;
        var panes: std.ArrayList(*Pane) = .empty;
        if (w_) |w| try windows.append(a, w) else for (self.windows.items) |w| if (!w.removed and w.session == s_.?) try windows.append(a, w);
        // Every descendant, before any effect; no partial cascade.
        for (windows.items) |w| {
            if (s_ != null and !self.registry.allows(c.conn.identity, .write, .{ .kind = "window", .id = w.id }, now_s)) return deniedDescendant(c);
            for (self.panes.items) |p| if (!p.removed and p.window == w) {
                if (!self.registry.allows(c.conn.identity, .write, .{ .kind = "pane", .id = p.id }, now_s)) return deniedDescendant(c);
                try panes.append(a, p);
            };
        }
        const sealed = if (w_) |w| w.sealed > 0 or w.session.sealed > 0 else s_.?.sealed > 0;
        if (sealed) return fail(c, "conflict.removing");
        for (panes.items) |p| if (p.pane.status != null and !p.exit_published) try self.publishExit(p);
        try self.ops.ensureUnusedCapacity(self.a, 1);
        const op = try self.newOp(c, if (w_ != null) .window else .session, windows.items, panes.items, s_);
        var listed = false;
        defer if (!listed) self.freeOp(op);
        const name = signalParam(c);
        const sig = posixSignal(name);
        const deadline = self.deadlineParam(c);
        var batch = try Batch.init(self.events);
        defer batch.deinit();
        for (panes.items) |p| if (p.pane.status == null and !p.pane.terminating) try self.terminatingEvents(&batch, a, p, name, .removal);
        try batch.reserve();
        // Effects start here: seal, then signal with one shared deadline.
        self.seal(op, true);
        const started = try a.alloc(bool, panes.items.len);
        @memset(started, false);
        var all_started = true;
        for (panes.items, 0..) |p, i| if (p.pane.status == null) {
            const r = self.leaders.terminate(p.leader.?, .{ .signal = sig, .deadline = deadline }) catch |err| {
                // Out of memory mid-way: what was signalled stays supervised.
                for (panes.items[0..i], started[0..i]) |q, st| if (st) self.startedTerminating(q, .removal);
                self.abandon(op);
                return err;
            };
            switch (r) {
                .already_exited => all_started = all_started and p.pane.terminating,
                .started => |id| {
                    op.requests[i] = id;
                    started[i] = true;
                },
                .joined => |id| op.requests[i] = id,
            }
        };
        for (panes.items, started) |p, st| if (st) self.startedTerminating(p, .removal);
        if (all_started) batch.commit() else {
            // A leader exited unobserved between staging and signalling:
            // announce only the terminations that really started.
            var exact = try Batch.init(self.events);
            defer exact.deinit();
            for (panes.items, started) |p, st| if (st) try self.terminatingEvents(&exact, a, p, name, .removal);
            try exact.reserve();
            exact.commit();
        }
        self.ops.appendAssumeCapacity(op);
        listed = true;
        // A subtree with no live panes commits in this same turn.
        if (opReady(op)) self.advance();
    }
    fn deniedDescendant(c: *proto.Call) !void {
        var principal_buf: [24]u8 = undefined;
        return c.fail("denied.write", "caller lacks the required grant", .{ .right = "write", .principal = g.name(c.conn.identity.principal, &principal_buf) });
    }
    fn newOp(self: *Product, c: *proto.Call, kind: @FieldType(Op, "kind"), windows: []const *Window, panes: []const *Pane, s_: ?*Session) !*Op {
        const op = try self.a.create(Op);
        errdefer self.a.destroy(op);
        const ws = try self.a.dupe(*Window, windows);
        errdefer self.a.free(ws);
        const ps = try self.a.dupe(*Pane, panes);
        errdefer self.a.free(ps);
        const rs = try self.a.alloc(?RequestId, panes.len);
        @memset(rs, null);
        op.* = .{ .ticket = c.ticket, .dispatcher = c.dispatcher, .kind = kind, .session = s_, .windows = ws, .panes = ps, .requests = rs };
        return op;
    }
    fn freeOp(self: *Product, op: *Op) void {
        self.a.free(op.windows);
        self.a.free(op.panes);
        self.a.free(op.requests);
        self.a.destroy(op);
    }
    fn seal(_: *Product, op: *Op, on: bool) void {
        if (op.kind == .kill or op.kind == .cancel) return;
        if (op.session) |s| s.sealed = if (on) s.sealed + 1 else s.sealed - 1;
        for (op.windows) |w| w.sealed = if (on) w.sealed + 1 else w.sealed - 1;
        for (op.panes) |p| p.sealed = if (on) p.sealed + 1 else p.sealed - 1;
    }
    /// Ends an op without removal: requests dropped (termination continues
    /// to its deadline and exits are reaped), seal lifted.
    fn abandon(self: *Product, op: *Op) void {
        for (op.requests) |r| if (r) |id| {
            _ = self.leaders.cancel(id);
        };
        self.seal(op, false);
        for (self.ops.items, 0..) |item, i| if (item == op) {
            _ = self.ops.orderedRemove(i);
            break;
        };
        self.freeOp(op);
    }
    fn opReady(op: *const Op) bool {
        for (op.panes) |p| if (!p.removed and (p.pane.status == null or !p.exit_published)) return false;
        return true;
    }
    /// Answers every op whose completion condition holds, or that timed out;
    /// drops ops whose call has ended (cancel, closed connection, shutdown).
    fn advance(self: *Product) void {
        var i: usize = 0;
        while (i < self.ops.items.len) {
            const op = self.ops.items[i];
            const open = op.dispatcher.get(op.ticket) orelse {
                self.abandon(op);
                continue;
            };
            if (!op.timed_out and !opReady(op)) {
                i += 1;
                continue;
            }
            self.complete(op, open) catch {
                if (op.dispatcher.get(op.ticket)) |still| fail(still, "internal") catch {};
            };
            self.abandon(op);
        }
    }
    fn complete(self: *Product, op: *Op, open: *proto.Call) !void {
        if (op.timed_out) {
            self.timeouts += 1;
            var names: std.ArrayList([]const u8) = .empty;
            for (op.panes) |p| if (!p.removed and p.pane.status == null) try names.append(open.arena(), p.id);
            return open.fail("timeout.terminate", "pane did not exit after SIGKILL", .{ .panes = names.items });
        }
        switch (op.kind) {
            .kill, .cancel => try self.finishKill(open, op.panes[0], !op.already, op.remove, op.kind == .cancel),
            .window, .session => {
                for (op.requests) |*r| r.* = null; // all exited; nothing to cancel
                try self.commitRemoval(open, null, op.windows, op.session, struct {}{});
            },
        }
    }
    fn requestDone(self: *Product, id: RequestId, outcome: supervisor.leaders.Outcome) void {
        for (self.ops.items) |op| for (op.requests, 0..) |*r, i| if (r.* != null and r.*.? == id) {
            r.* = null;
            if (outcome == .timeout) {
                op.timed_out = true;
                op.panes[i].stuck = true;
            }
            return;
        };
    }
    fn discardLeader(self: *Product, l: *Leader) void {
        if (self.leaders.terminate(l, .{ .signal = .KILL, .deadline = self.leaders.now() })) |r| switch (r) {
            .started, .joined => |id| _ = self.leaders.cancel(id),
            .already_exited => {},
        } else |_| _ = std.c.kill(-l.pid, .KILL); // still pinned: unreaped
        self.discarded.appendAssumeCapacity(l);
    }
    fn toExit(status: ?supervisor.leaders.Status) stream.Exit {
        const s = status orelse return .{ .signal = "SIGUNKNOWN" };
        return switch (s) {
            .code => |code| .{ .code = code },
            .signal => |sig| .{ .signal = stream.signalName(sig.number) },
        };
    }
    /// One supervision turn, before streams are pumped: reap exited
    /// leaders (after their group sweep) and route request outcomes.
    pub fn supervise(self: *Product) !void {
        try self.leaders.tick();
        while (self.leaders.nextEvent()) |event| switch (event) {
            .exited => |l| found: {
                // Status exec sources.
                if (@import("status_exec.zig").exited(self, l)) break :found;
                for (self.discarded.items, 0..) |d, i| if (d == l) {
                    _ = self.discarded.swapRemove(i);
                    self.leaders.release(l) catch {};
                    break :found;
                };
                for (self.panes.items) |p| if (p.leader == l) {
                    p.pane.reaped = toExit(l.status);
                    // The run's only source of completion.
                    if (p.run) |r| r.wait = l.status;
                    // Kept on the pane: the leader is released at removal,
                    // possibly before a joined request is answered.
                    p.escalated = l.escalated;
                    p.stuck = false;
                    if (l.escalated) self.escalations += 1;
                    break :found;
                };
            },
            .done => |d| self.requestDone(d.request, d.outcome),
        };
    }
    /// Shutdown takes over every live leader with SIGHUP and the shutdown
    /// deadline; in-flight requests have already been cancelled.
    pub fn shutdownLeaders(self: *Product, deadline: i64) void {
        while (self.ops.items.len > 0) self.abandon(self.ops.items[0]);
        @import("status_exec.zig").shutdown(self, deadline);
        for (self.panes.items) |p| if (p.leader) |l| if (l.phase != .exited) {
            if (p.run) |r| self.runs.terminating(r, .shutdown);
            if (self.leaders.terminate(l, .{ .signal = .HUP, .deadline = deadline })) |r| switch (r) {
                .started, .joined => |id| _ = self.leaders.cancel(id),
                .already_exited => {},
            } else |_| _ = std.c.kill(-l.pid, .KILL);
        };
    }
    pub fn terminatingCount(self: *const Product) usize {
        var n: usize = 0;
        for (self.panes.items) |p| if (!p.removed and p.pane.terminating) {
            n += 1;
        };
        return n;
    }
    pub fn orphansReaped(self: *const Product) u64 {
        return if (self.orphans_reaped) |n| n.load(.monotonic) else 0;
    }
    pub fn discardedInput(self: *const Product) u64 {
        var n = self.discarded_input;
        for (self.panes.items) |p| if (!p.removed) {
            n += p.pane.discarded_input;
        };
        return n;
    }
    pub fn removedRecords(self: *const Product) usize {
        var n: usize = 0;
        for (self.sessions.items) |x| n += @intFromBool(x.removed);
        for (self.windows.items) |x| n += @intFromBool(x.removed);
        for (self.panes.items) |x| n += @intFromBool(x.removed);
        return n;
    }
    /// The process a live pane runs: what its principal is bound to, so another daemon can tell it from a reused PID. Null once
    /// it has exited, and for a pane restored without one.
    fn liveRoot(self: *const Product, p: *const Pane) ?proto.process.Ref {
        if (p.pane.status != null) return null;
        const pty = p.pane.pty orelse return null;
        const root = (self.registry.get(p.principal) orelse return null).root orelse return null;
        return if (root.pid == pty.pid) root else null;
    }
    fn jsonValue(a: std.mem.Allocator, v: anytype) !Value {
        return std.json.parseFromSliceLeaky(Value, a, try std.json.Stringify.valueAlloc(a, v, .{ .emit_null_optional_fields = false }), .{});
    }
    /// The base spawn environment, captured once from the daemon's own.
    pub fn baseEnv(self: *Product) !*const spawn_env.Base {
        if (self.base == null) self.base = try spawn_env.Base.init(self.a, self.environ);
        return &self.base.?;
    }
    pub fn envInvalid(self: *Product, c: *proto.Call, f: spawn_env.Failure) !void {
        self.env_failures[spawn_env.reasonIndex(&spawn_env.env_reasons, f.reason)] += 1;
        const message: []const u8 = if (eq(u8, f.reason, "reserved")) "reserved environment variable" else if (eq(u8, f.reason, "credential") or eq(u8, f.reason, "owner_credential")) "credential not allowed in environment" else if (eq(u8, f.reason, "count") or eq(u8, f.reason, "size")) "environment too large" else if (eq(u8, f.reason, "duplicate")) "duplicate environment variable" else "invalid environment variable";
        return c.fail("invalid_params.env", message, .{ .param = f.param, .reason = f.reason });
    }
    fn cwdMissing(self: *Product, c: *proto.Call) !void {
        self.cwd_not_found += 1;
        return c.fail("not_found.cwd", "working directory not found", struct {}{});
    }
    fn cwdUnavailable(self: *Product, c: *proto.Call, reason: []const u8) !void {
        self.cwd_failures[spawn_env.reasonIndex(&spawn_env.cwd_reasons, reason)] += 1;
        return c.fail("unavailable.cwd", "working directory unavailable", .{ .reason = reason });
    }
    fn spawnUnavailable(self: *Product, c: *proto.Call, reason: []const u8) !void {
        self.spawn_failures[spawn_env.reasonIndex(&spawn_env.spawn_reasons, reason)] += 1;
        const message: []const u8 = if (eq(u8, reason, "not_found")) "executable not found" else if (eq(u8, reason, "permission")) "permission denied" else if (eq(u8, reason, "exec_format")) "exec format error" else if (eq(u8, reason, "too_large")) "argument list too long" else if (eq(u8, reason, "resource")) "resources unavailable" else "spawn failed";
        return c.fail("unavailable.spawn", message, .{ .reason = reason });
    }
    /// Cwd and environment resolution, after authorization and every syntactic check.
    /// Returns null once the call has been answered.
    fn resolveCwd(self: *Product, c: *proto.Call, scratch: *spawn_env.Scratch, cwd: []const u8) !?[:0]const u8 {
        seam.resolving();
        const path = try scratch.printZ("{s}", .{cwd});
        var buf: [std.posix.PATH_MAX]u8 = undefined;
        defer std.crypto.secureZero(u8, &buf);
        if (realpath(path.ptr, &buf) == null) {
            const errno = std.c.errno(@as(c_int, -1));
            if (errno == .NOENT or errno == .NOTDIR) {
                try self.cwdMissing(c);
                return null;
            }
            try self.cwdUnavailable(c, if (errno == .ACCES) "permission" else "other");
            return null;
        }
        const resolved = try scratch.printZ("{s}", .{std.mem.sliceTo(&buf, 0)});
        const info = proto.os.statAt(std.c.AT.FDCWD, resolved, 0) catch {
            try self.cwdMissing(c);
            return null;
        };
        if (info.mode & std.c.S.IFMT != std.c.S.IFDIR) {
            try self.cwdMissing(c);
            return null;
        }
        seam.resolved(resolved);
        return resolved;
    }
    /// Pane creation with its cwd and environment, in this
    /// order: authorization, lookup and conflicts precede this call;
    /// then delegation, syntax, cwd resolution, preparation and exec.
    /// `archive` is a `pane.relaunch`: the new pane replaces that leaf at
    /// its saved size in the same commit; nothing else is taken from it.
    pub fn spawn(self: *Product, c: *proto.Call, session_: *Session, split: ?*Pane, run: ?*runs_mod.Start, archive: ?*Pane) !void {
        var place: floats.Place = .{};
        // A float archive's relaunch stays in the float layer with the same
        // spec and z-order; a tiled one replaces its leaf.
        if (archive) |old| if (old.float) |f| {
            place = .{ .layer = old.layer, .window = old.window, .float = try floats.Float.create(self.a, f.preset, f.explicit) };
            _ = try self.floats.place(place.float.?);
            place.float.?.z = f.z;
        };
        defer if (place.float) |f| f.destroy(self.a);
        return self.spawnWith(c, session_, split, run, archive, &place);
    }
    /// A floating pane or popup in an existing window.
    pub fn spawnPlaced(self: *Product, c: *proto.Call, session_: *Session, place: *floats.Place) !void {
        return self.spawnWith(c, session_, null, null, null, place);
    }
    fn spawnWith(self: *Product, c: *proto.Call, session_: *Session, split: ?*Pane, run: ?*runs_mod.Start, archive: ?*Pane, place: *floats.Place) !void {
        const a = c.arena();
        const conn = c.conn;
        const creator = c.conn.identity.principal;
        // Panes in an existing window: a split or a relaunched archive.
        const source = split orelse archive;
        // A float or popup joins its window outside the split tree.
        const placed = place.layer != .tile;
        const existing: ?*Window = if (placed) place.window.? else if (source) |x| x.window else null;
        const name = if (existing == null) text(c, "name") else "";
        if (!nameValid(name)) return c.fail("invalid_params.name", "invalid display name", .{ .param = "name" });
        const saved = if (archive) |x| x.pane.vt.size() else null;
        const cols: i64 = if (saved) |z| z.cols else c.params.object.get("cols").?.integer;
        const rows: i64 = if (saved) |z| z.rows else c.params.object.get("rows").?.integer;
        if (cols < 1 or cols > 65535 or rows < 1 or rows > 65535) return c.fail("invalid_params.size", "invalid size", .{ .param = if (cols < 1 or cols > 65535) "cols" else "rows" });
        try self.panes.ensureUnusedCapacity(self.a, 1);
        try self.streams.panes.ensureUnusedCapacity(self.a, 1);
        if (existing == null) try self.windows.ensureUnusedCapacity(self.a, 1);
        try self.discarded.ensureUnusedCapacity(self.a, 1);
        const base = try self.baseEnv();
        // Delegation. The pane ID is consumed from here on.
        const id_ = try self.allocateId('p', &self.streams.next_pane);
        defer self.a.free(id_);
        var gs: ?[]g.Grant = null;
        if (c.params.object.get("grants")) |v| {
            gs = try a.alloc(g.Grant, v.array.items.len);
            for (v.array.items, gs.?) |item, *entry| entry.* = .{ .right = std.meta.stringToEnum(g.Right, item.object.get("right").?.string).?, .scope = item.object.get("scope").?.string };
        }
        const issued = self.registry.issueChild(c.conn.identity, .{ .kind = .pane, .pane = id_, .grants = gs }, g.nowSeconds()) catch |err| {
            if (err == error.OutOfMemory) return err;
            return fail(c, "denied.delegation");
        };
        defer {
            std.crypto.secureZero(u8, @constCast(issued.token));
            self.a.free(issued.token);
        }
        var committed = false;
        defer if (!committed) {
            if (self.principals) |e| e.silence(issued.principal);
            self.registry.revoke(.{ .principal = g.owner }, issued.principal, g.nowSeconds()) catch {};
        };
        // Syntax of argv, cwd, env / env_unset, in that order.
        const argv = c.params.object.get("argv").?.array.items;
        if (argv.len == 0 or argv[0].string.len == 0) return c.fail("invalid_params.argv", "empty argv", .{ .param = "argv" });
        const args = try a.allocSentinel(?[*:0]const u8, argv.len, null);
        for (argv, args) |v, *arg| {
            if (std.mem.indexOfScalar(u8, v.string, 0) != null) return c.fail("invalid_params.argv", "NUL in argv", .{ .param = "argv" });
            arg.* = (try a.dupeSentinel(u8, v.string, 0)).ptr;
        }
        // The search name; argv is passed to the program as given.
        const program: []const u8 = if (c.params.object.get("program")) |v| v.string else argv[0].string;
        if (program.len == 0) return c.fail("invalid_params.argv", "empty program", .{ .param = "program" });
        if (std.mem.indexOfScalar(u8, program, 0) != null) return c.fail("invalid_params.argv", "NUL in program", .{ .param = "program" });
        // `run` panes keep their own retention rules; a relaunch
        // keeps the archive's recorded policy. Read before the call is answered.
        const on_exit: Policy = if (run != null) .keep else if (archive) |old| old.on_exit else Policy.param(c, "on_exit");
        const cwd_param: ?[]const u8 = if (c.params.object.get("cwd")) |v| v.string else null;
        if (cwd_param) |dir| if (spawn_env.checkCwd(dir)) |reason| {
            const message: []const u8 = if (eq(u8, reason, "relative")) "cwd must be an absolute path" else if (eq(u8, reason, "size")) "cwd too long" else "NUL in cwd";
            return c.fail("invalid_params.cwd", message, .{ .param = "cwd", .reason = reason });
        };
        const request = spawn_env.Request.from(c.params.object);
        if (try spawn_env.check(a, request)) |f| return self.envInvalid(c, f);
        // Caller tags plus the daemon-set `owner`.
        var tags = (try chrome.creationTags(self.a, c)) orelse return;
        defer if (!committed) tags.deinit(self.a);
        // Every string that may hold a value, the token or the cwd is zeroed.
        var scratch: spawn_env.Scratch = .{ .a = self.a };
        defer scratch.deinit();
        // The first filesystem access.
        const cwd: ?[:0]const u8 = if (cwd_param) |dir| (try self.resolveCwd(c, &scratch, dir)) orelse return else null;
        // Preparation; every allocation and event precedes fork/exec.
        const w = existing orelse try self.a.create(Window);
        defer if (!committed and existing == null) self.a.destroy(w);
        const wid = if (existing != null) w.id else try self.allocateId('w', &self.next_window);
        defer if (!committed and existing == null) self.a.free(wid);
        const owned_name = if (existing != null) w.name else try self.a.dupe(u8, name);
        defer if (!committed and existing == null) self.a.free(owned_name);
        if (source != null and !placed and w.revision == proto.events.max_seq) return error.Overflow;
        const pane_ = try stream.Pane.create(self.a, id_, .{ .cols = @intCast(cols), .rows = @intCast(rows) }, self.streams.config);
        defer if (!committed) pane_.destroy();
        const p = try self.a.create(Pane);
        defer if (!committed) self.a.destroy(p);
        const record_id = try self.a.dupe(u8, id_);
        defer if (!committed) self.a.free(record_id);
        // Derived once from the argv[0] that is executed.
        const argv0_label = spawn_env.argv0Label(argv[0].string);
        const owned_argv0: ?[]const u8 = if (argv0_label) |l| try self.a.dupe(u8, l) else null;
        defer if (!committed) if (owned_argv0) |x| self.a.free(x);
        const nodes = if (placed) w.nodes else if (archive) |old| try layout.replace(self.a, w.nodes, old.id, record_id) else if (split) |old| try layout.editSplit(self.a, w.nodes, old.id, .{ .kind = .pane, .pane = record_id, .axis = place.axis orelse std.meta.stringToEnum(layout.Axis, text(c, "axis")).? }, PaneSizes{ .product = self }) else try self.a.dupe(Node, &.{.{ .kind = .pane, .pane = record_id }});
        defer if (!committed and !placed) self.a.free(nodes);
        var principal_buf: [24]u8 = undefined;
        const principal = g.name(issued.principal, &principal_buf);
        const built = try spawn_env.build(&scratch, base.*, request, .{ .token = issued.token, .principal = principal, .pane = id_, .socket = self.socket, .run = if (run) |r| r.id else "" }, cwd);
        const candidates = try spawn_env.candidates(&scratch, program, built.path);
        var batch = try Batch.init(self.events);
        defer batch.deinit();
        if (existing == null) try batch.append(try resourceName(a, "window", wid), "window.created", .{ .window = wid, .session = session_.id, .name = name, .revision = @as(u64, 1), .nodes = nodes });
        // Relaunch order: archive pane.removed, pane.created, layout.
        if (archive) |old| try self.paneRemovalEvents(&batch, a, old);
        if (placed) {
            const f = place.float.?;
            try batch.append(try resourceName(a, "pane", id_), "pane.created", .{ .pane = id_, .session = session_.id, .layer = @tagName(place.layer), .window = wid, .float = try f.wire(a), .client = if (f.client) |x| x.id else null, .tags = tags.items.items, .argv0 = argv0_label });
        } else try batch.append(try resourceName(a, "pane", id_), "pane.created", .{ .pane = id_, .session = session_.id, .tags = tags.items.items, .argv0 = argv0_label });
        if (source != null and !placed) try batch.append(try resourceName(a, "window", wid), "window.layout_changed", .{ .window = wid, .session = session_.id, .revision = w.revision + 1, .nodes = nodes });
        // The run, its pane and its key binding commit together.
        const record: ?*runs_mod.Run = if (run) |r| try self.runs.prepare(self.a, r, creator, id_, wid, session_.id, principal) else null;
        defer if (!committed) if (record) |r| self.runs.discard(self.a, r);
        if (record) |r| try batch.append(try resourceName(a, "run", r.id), "run.started", .{ .run = r.id, .pane = id_ });
        // The pane's principal is announced with the pane. It
        // takes its creator's expiry (also set again once the process is known).
        self.registry.entries.items[@intCast(issued.principal)].expires = self.registry.get(c.conn.identity.principal).?.expires;
        try principal_events.appendCreated(&batch, a, self.registry, issued.principal);
        try batch.reserve();
        if (seam.fails("prepare")) return self.spawnUnavailable(c, "resource");
        try pane_.setTerminfo(built.term);
        var prepared = Pty.prepare(.{ .candidates = candidates, .argv = args.ptr, .env = built.envp, .cwd = if (cwd) |d| d.ptr else null }, pane_.vt.size()) catch return self.spawnUnavailable(c, "resource");
        var started = false;
        defer if (!started) prepared.abort();
        // Adopt while the child waits at its start barrier: from here only
        // Leaders waits on it, and a failed spawn hands it to discardLeader.
        if (seam.fails("adopt")) return self.spawnUnavailable(c, "resource");
        const leader = self.leaders.adopt(prepared.pty.pid) catch |err| {
            if (err == error.OutOfMemory) return err;
            return self.spawnUnavailable(c, "resource");
        };
        prepared.pty.supervised = true;
        defer if (!committed) self.discardLeader(leader);
        seam.spawned(program, prepared.pty.pid);
        if (seam.fails("stat")) return self.spawnUnavailable(c, "other");
        const root = proto.process.stat(prepared.pty.pid) catch return self.spawnUnavailable(c, "other");
        self.registry.entries.items[@intCast(issued.principal)].root = root.ref;
        self.registry.entries.items[@intCast(issued.principal)].expires = self.registry.get(c.conn.identity.principal).?.expires;
        if (seam.fails("start")) return self.spawnUnavailable(c, "other");
        // Before the barrier is released a closed connection
        // rolls the start back; after it the start completes normally.
        if (run != null) {
            seam.runBarrier(c.conn);
            if (c.conn.closing) return c.fail("cancelled", "request cancelled before the program started", null);
        }
        pane_.pty = prepared.start() catch |err| {
            const failure = prepared.failure orelse return self.spawnUnavailable(c, if (err == error.ExecFailed) "other" else "resource");
            return switch (failure.phase) {
                .cwd => self.cwdUnavailable(c, spawn_env.chdirReason(failure.errno)),
                .exec => self.spawnUnavailable(c, spawn_env.execReason(failure.errno)),
            };
        };
        started = true;
        if (run) |r| {
            try runs_mod.sized(c, .{ .run = r.id, .source = self.events.source, .key = r.key, .pane = id_, .window = wid, .session = session_.id, .principal = principal, .pid = @as(i64, pane_.pty.?.pid), .reused = false });
        } else try result(c, .{ .pane = id_, .window = wid, .session = session_.id, .principal = principal, .pid = pane_.pty.?.pid });
        if (existing == null) {
            w.* = .{ .id = wid, .name = owned_name, .session = session_, .owner = creator, .nodes = nodes };
            self.windows.appendAssumeCapacity(w);
        } else if (!placed) {
            self.a.free(w.nodes);
            w.nodes = nodes;
            w.revision += 1;
        }
        p.* = .{ .id = record_id, .window = w, .owner = creator, .principal = issued.principal, .pane = pane_, .argv0 = owned_argv0, .observation = Observation.init(self.a, self.events, record_id), .leader = leader, .run = record, .on_exit = on_exit, .tags = tags, .layer = place.layer, .float = place.float };
        if (placed) {
            place.float = null;
            self.floats.next_z = @max(self.floats.next_z, p.float.?.z);
            if (place.ticket) |t| floats.consume(self, t);
        }
        pane_.observers = p.observation.callbacks();
        pane_.reset_observer = Observation.reset;
        self.panes.appendAssumeCapacity(p);
        self.streams.panes.appendAssumeCapacity(pane_);
        // The archive's streams close with pane_removed; its ID is never reused.
        if (archive) |old| self.retirePane(old);
        batch.commit();
        committed = true;
        if (record) |r| {
            self.runs.commit(r, run.?, pane_.pty.?.pid, pane_.vt.rows().epoch, self.leaders.now());
            seam.runCommitted(conn);
        }
        return;
    }
    pub fn tick(self: *Product) !void {
        const clock = self.leaders.now();
        for (self.panes.items) |p| if (!p.removed) {
            if (p.observation.failed) return error.ObservationFailed;
            // A command start or finish makes the title stale.
            const commanded = p.observation.command_epoch != p.fg.command_epoch;
            if (commanded) {
                p.fg.command_epoch = p.observation.command_epoch;
                p.fg.title_current = false;
            }
            const output = p.last_output != p.pane.ring.head;
            // The title waits for a sample, so a process change its program
            // caused is published first; both are rate-bounded together.
            var title_ready = true;
            if (p.pane.status == null) if (p.pane.pty) |pty| {
                const last = p.fg.sampled_ms orelse std.math.minInt(i32);
                if (foreground.due(output or commanded, last, clock)) {
                    try self.sampleForeground(p, pty.fd);
                    p.fg.sampled_ms = clock;
                } else title_ready = false;
            };
            if (output and title_ready) {
                const title = try p.pane.vt.title();
                if (!eq(u8, p.title, title)) {
                    const owned = try self.a.dupe(u8, title);
                    errdefer self.a.free(owned);
                    var scratch = std.heap.ArenaAllocator.init(self.a);
                    defer scratch.deinit();
                    try self.events.append(try resourceName(scratch.allocator(), "pane", p.id), "pane.title_changed", .{ .pane = p.id, .title = title });
                    if (p.title.len > 0) self.a.free(p.title);
                    if (owned.len == 0) self.a.free(owned);
                    p.title = if (owned.len > 0) owned else "";
                    p.fg.title_current = p.title.len > 0;
                }
                p.last_output = p.pane.ring.head;
            }
            try chrome.observe(self, p);
            if (!p.exit_published and p.pane.status != null) try self.publishExit(p);
        };
        // on_exit removal follows pane.exited in a later commit.
        try self.removeExited();
        // Exits are committed before any termination response depends on them.
        self.advance();
        try self.runDeadlines();
        const now = self.leaders.now();
        self.runs.serve(self.events.source, now);
        try self.runs.evict(self.a, self.events, now);
        self.sweepRecords();
        try chrome.tickSources(self);
        chrome.tick(self);
        keys_registry.tick(self);
        try floats.tick(self);
    }
    /// Any live pane (tiled, float or popup) in `w`.
    fn windowHasPanes(self: *Product, w: *Window) bool {
        for (self.panes.items) |p| if (!p.removed and p.window == w) return true;
        return false;
    }
    /// SIGHUP with 2000 ms grace and no waiting request (a popup whose
    /// client detached).
    pub fn hangUp(self: *Product, p: *Pane) !void {
        var scratch = std.heap.ArenaAllocator.init(self.a);
        defer scratch.deinit();
        var batch = try Batch.init(self.events);
        defer batch.deinit();
        const starts = !p.pane.terminating;
        if (starts) try self.terminatingEvents(&batch, scratch.allocator(), p, "SIGHUP", .removal);
        try batch.reserve();
        switch (try self.leaders.terminate(p.leader.?, .{ .signal = .HUP, .deadline = self.leaders.now() + 2000 })) {
            .already_exited => {},
            .started => |id| {
                _ = self.leaders.cancel(id);
                self.startedTerminating(p, .removal);
                batch.commit();
            },
            .joined => |id| _ = self.leaders.cancel(id),
        }
    }
    /// The stream server's hook for every closed connection
    /// (`bind = connection`).
    pub fn connectionClosed(ctx: *anyopaque, conn: *proto.Connection) void {
        const self: *Product = @ptrCast(@alignCast(ctx));
        chrome.closed(self, conn);
        keys_registry.closed(self, conn);
        floats.closed(self, conn);
    }
    fn attentionValue(p: *const Pane) ?struct { level: []const u8, reason: []const u8, revision: u64 } {
        if (p.attention.level == .none) return null;
        return .{ .level = @tagName(p.attention.level), .reason = p.attention.reason, .revision = p.attention.revision };
    }
    /// A run's `deadline`: SIGHUP with 2000 ms grace, measured on the
    /// monotonic clock from commit; no request waits on it.
    fn runDeadlines(self: *Product) !void {
        const now = self.leaders.now();
        for (self.panes.items) |p| if (p.run) |r| if (r.state == .running) if (r.deadline) |d| if (now >= d and !p.removed and p.pane.status == null) {
            var scratch = std.heap.ArenaAllocator.init(self.a);
            defer scratch.deinit();
            var batch = try Batch.init(self.events);
            defer batch.deinit();
            const starts = !p.pane.terminating;
            if (starts) try self.terminatingEvents(&batch, scratch.allocator(), p, "SIGHUP", .deadline);
            try batch.reserve();
            switch (try self.leaders.terminate(p.leader.?, .{ .signal = .HUP, .deadline = now + 2000 })) {
                .already_exited => {},
                .started => |id| {
                    _ = self.leaders.cancel(id);
                    self.startedTerminating(p, .deadline);
                    batch.commit();
                },
                .joined => |id| _ = self.leaders.cancel(id),
            }
        };
    }
    /// Whether an exited pane is due for on_exit removal: published
    /// exit, live record, not a run or an archive, and not covered by an
    /// termination request (that request removes or keeps it itself).
    fn exitRemovable(self: *Product, p: *Pane) bool {
        const orphan = if (p.float) |f| f.orphaned else false;
        return (p.on_exit == .remove or orphan) and !p.removed and p.exit_published and p.run == null and p.archive == null and
            p.sealed == 0 and p.window.sealed == 0 and p.window.session.sealed == 0 and !self.inOp(p);
    }
    fn removeExited(self: *Product) !void {
        if (self.shutting_down or self.lifecycle.stopping()) return;
        var i: usize = 0;
        while (i < self.panes.items.len) : (i += 1) {
            const p = self.panes.items[i];
            if (self.exitRemovable(p)) try self.cascade(p);
        }
    }
    /// One commit: the pane (`pane.removed` reason on_exit), its window if
    /// that leaves it empty (`window.removed` reason empty, else
    /// `window.layout_changed`), then an on_empty=remove session left
    /// without windows (`session.removed` reason empty). The last session's
    /// removal is an explicit removal for the daemon lifecycle.
    fn cascade(self: *Product, p: *Pane) !void {
        var scratch = std.heap.ArenaAllocator.init(self.a);
        defer scratch.deinit();
        const a = scratch.allocator();
        const w = p.window;
        const s = w.session;
        const tiled = p.layer == .tile;
        if (tiled and w.revision == proto.events.max_seq) return error.Overflow;
        const nodes = if (tiled) try layout.edit(self.a, w.nodes, p.id, null) else w.nodes;
        var committed = false;
        defer if (!committed and tiled) self.a.free(nodes);
        // Floats and popups keep a window like tiled panes.
        const window_empty = nodes.len == 0 and for (self.panes.items) |x| {
            if (x != p and !x.removed and x.window == w) break false;
        } else true;
        var others: usize = 0;
        for (self.windows.items) |x| if (!x.removed and x.session == s and x != w) {
            others += 1;
        };
        const session_empty = window_empty and others == 0 and s.on_empty == .remove;
        var batch = try Batch.init(self.events);
        defer batch.deinit();
        if (p.observation.records.len > 0) try batch.append(try resourceName(a, "pane", p.id), "program.status_changed", .{ .pane = p.id, .reason = "pane_removed", .records = p.observation.records[0..0] });
        try batch.append(try resourceName(a, "pane", p.id), "pane.removed", .{ .pane = p.id, .reason = "on_exit" });
        if (window_empty) {
            try batch.append(try resourceName(a, "window", w.id), "window.removed", .{ .window = w.id, .session = s.id, .reason = "empty" });
        } else if (tiled) try batch.append(try resourceName(a, "window", w.id), "window.layout_changed", .{ .window = w.id, .session = s.id, .revision = w.revision + 1, .nodes = nodes });
        if (session_empty) try batch.append(try resourceName(a, "session", s.id), "session.removed", .{ .session = s.id, .reason = "empty" });
        try batch.reserve();
        // From here nothing fails.
        if (tiled) {
            self.a.free(w.nodes);
            w.nodes = nodes;
            w.revision += 1;
        }
        committed = true;
        self.retirePane(p);
        if (window_empty) w.removed = true;
        if (session_empty) s.removed = true;
        batch.commit();
        if (session_empty) self.lifecycle.removed(self.liveSessions());
        self.registry.revoke(.{ .principal = g.owner }, p.principal, g.nowSeconds()) catch {};
    }
    /// Read the foreground group; read its name only when the
    /// group changed; publish `pane.process_changed` when the name changed.
    fn sampleForeground(self: *Product, p: *Pane, fd: std.c.fd_t) !void {
        const pgid = foreground.group(fd) orelse 0;
        if (pgid != 0 and pgid == p.fg.pgid) return;
        p.fg.pgid = pgid;
        var buf: [256]u8 = undefined;
        const next: ?[]const u8 = if (pgid != 0) foreground.name(pgid, &buf) else null;
        const old = p.fg.process();
        if ((old == null and next == null) or (old != null and next != null and eq(u8, old.?, next.?))) return;
        var scratch = std.heap.ArenaAllocator.init(self.a);
        defer scratch.deinit();
        try self.events.append(try resourceName(scratch.allocator(), "pane", p.id), "pane.process_changed", .{ .pane = p.id, .process = next });
        p.fg.set(next);
        p.fg.title_current = false;
    }
    fn publishExit(self: *Product, p: *Pane) !void {
        const status = p.pane.status.?;
        var scratch = std.heap.ArenaAllocator.init(self.a);
        defer scratch.deinit();
        try p.observation.finish("pane_exit", null);
        try p.observation.cleanup("process_exit", false);
        try self.events.append(try resourceName(scratch.allocator(), "pane", p.id), "pane.exited", .{ .pane = p.id, .exit_code = if (status == .code) @as(?u8, status.code) else null });
        p.exit_published = true;
        // `pane.exited` implies no `process`; no event follows.
        p.fg.set(null);
        p.fg.pgid = 0;
        // `run.completed` follows `pane.exited` in this turn.
        if (p.run) |r| try self.runs.complete(self.a, r, p.pane.vt, p.pane.ring.head, self.leaders.now(), self.events);
    }
    fn retained(self: *Product, kind: []const u8, id: []const u8) bool {
        var buf: [64]u8 = undefined;
        const name = std.fmt.bufPrint(&buf, "{s}:{s}", .{ kind, id }) catch return true;
        for (self.events.entries.items[self.events.head..]) |e| if (eq(u8, e.resource, name)) return true;
        return false;
    }
    /// Removed resources stay as frozen authorization records
    /// while a retained event refers to them; free them once none does.
    fn sweepRecords(self: *Product) void {
        const low = self.events.low();
        if (low == self.records_low) return;
        self.records_low = low;
        self.runs.sweep(self.a, self.events);
        var i: usize = 0;
        while (i < self.panes.items.len) {
            const p = self.panes.items[i];
            // A run record (or its tombstone) keeps its pane's frozen
            // authorization data.
            if (p.removed and !self.retained("pane", p.id) and !self.inOp(p) and !self.runs.references(p.id)) {
                _ = self.panes.orderedRemove(i);
                if (p.archive) |x| x.destroy(self.a);
                p.observation.deinit();
                if (p.title.len != 0) self.a.free(p.title);
                if (p.argv0) |x| self.a.free(x);
                p.tags.deinit(self.a);
                p.attention.deinit(self.a);
                if (p.float) |f| f.destroy(self.a);
                self.a.free(p.id);
                self.a.destroy(p);
            } else i += 1;
        }
        i = 0;
        while (i < self.windows.items.len) {
            const w = self.windows.items[i];
            const used = for (self.panes.items) |p| {
                if (p.window == w) break true;
            } else false;
            if (w.removed and !used and !self.retained("window", w.id) and !self.inOpWindow(w) and !self.floats.refsWindow(w)) {
                _ = self.windows.orderedRemove(i);
                self.a.free(w.nodes);
                self.a.free(w.id);
                self.a.free(w.name);
                self.a.destroy(w);
            } else i += 1;
        }
        i = 0;
        while (i < self.sessions.items.len) {
            const x = self.sessions.items[i];
            const used = for (self.windows.items) |w| {
                if (w.session == x) break true;
            } else false;
            const op_ref = for (self.ops.items) |op| {
                if (op.session == x) break true;
            } else false;
            if (x.removed and !used and !op_ref and !self.retained("session", x.id) and !self.floats.refsSession(x)) {
                _ = self.sessions.orderedRemove(i);
                self.a.free(x.id);
                self.a.free(x.name);
                self.a.destroy(x);
            } else i += 1;
        }
    }
    fn inOp(self: *Product, p: *Pane) bool {
        for (self.ops.items) |op| for (op.panes) |q| if (q == p) return true;
        return false;
    }
    fn inOpWindow(self: *Product, w: *Window) bool {
        for (self.ops.items) |op| for (op.windows) |x| if (x == w) return true;
        return false;
    }
    pub fn capture(self: *Product, a: std.mem.Allocator) anyerror![]const proto.events.Entity {
        var out: std.ArrayList(proto.events.Entity) = .empty;
        for (self.sessions.items) |s| if (!s.removed) try out.append(a, .{ .resource = try resourceName(a, "session", s.id), .entity_type = "session", .content = try std.json.Stringify.valueAlloc(a, .{ .session = s.id, .name = s.name, .on_empty = if (s.on_empty == .remove) @as(?[]const u8, "remove") else null }, .{ .emit_null_optional_fields = false }), .event_types = &.{ "session.created", "session.removed" } });
        for (self.windows.items) |w| if (!w.removed) try out.append(a, .{ .resource = try resourceName(a, "window", w.id), .entity_type = "window", .content = try std.json.Stringify.valueAlloc(a, windowValue(w), .{ .emit_null_optional_fields = false }), .event_types = &.{ "window.created", "window.layout_changed", "window.removed" } });
        for (self.panes.items) |p| if (!p.removed) try out.append(a, .{ .resource = try resourceName(a, "pane", p.id), .entity_type = "pane", .content = try std.json.Stringify.valueAlloc(a, .{ .pane = p.id, .session = p.window.session.id, .title = p.title, .argv0 = p.argv0, .process = p.fg.process(), .title_current = if (p.pane.status == null) @as(?bool, p.fg.title_current) else null, .exited = p.pane.status != null, .exit_code = if (p.pane.status != null and p.pane.status.? == .code) @as(?u8, p.pane.status.?.code) else null, .terminating = if (p.pane.terminating) @as(?bool, true) else null, .on_exit = @tagName(p.on_exit), .recovery = recovery.metadata(p), .tags = p.tags.items.items, .attention = attentionValue(p), .layer = @tagName(p.layer), .window = p.window.id, .float = if (p.float) |f| try f.wire(a) else null, .client = if (p.float) |f| (if (f.client) |x| x.id else null) else null }, .{ .emit_null_optional_fields = false }), .event_types = &.{ "pane.created", "pane.terminating", "pane.exited", "pane.removed", "pane.title_changed", "pane.process_changed", "pane.tags_changed", "pane.attention_changed", "pane.placed", "pane.raised" } });
        for (self.panes.items) |p| if (!p.removed) try p.observation.appendSnapshot(a, &out);
        try self.runs.appendSnapshot(a, &out);
        try chrome.appendSnapshot(self, a, &out);
        return out.toOwnedSlice(a);
    }
};

test "resource creation allocation failures publish no ghosts, children or principals" {
    for ([_]bool{ false, true }) |with_process| {
        var completed = false;
        for (0..4096) |index| {
            if (try allocationTrial(index, with_process)) {
                completed = true;
                break;
            }
        }
        try std.testing.expect(completed);
    }
}
fn allocationTrial(index: usize, with_process: bool) !bool {
    const testing = std.testing;
    var fault = testing.FailingAllocator.init(testing.allocator, .{});
    const a = fault.allocator();
    var events = try proto.events.Log.init(a, "venomx", .{}, null);
    defer events.deinit();
    events.catalog = &@import("manifest.zig").catalog;
    var registry = try g.Registry.init(a, "venomx", .{});
    defer registry.deinit();
    var server = streams.Server.init(a, events.source);
    defer server.deinit();
    var leaders = supervisor.Leaders.init(a, .{});
    defer leaders.deinit();
    var product: Product = .{ .a = a, .streams = &server, .registry = &registry, .events = &events, .environ = .empty, .leaders = &leaders };
    defer product.deinit();
    registry.containment = g.Containment.init(&product);
    const bindings_ = product.bindings() ++ .{proto.Binding{ .verb = "events", .handler = proto.VerbHandler.init(&events) }};
    var dispatcher = try proto.Dispatcher.init(testing.allocator, &@import("manifest.zig").core_model, &bindings_, .{}, null);
    defer dispatcher.deinit();
    var conn = proto.Connection.init(testing.allocator, -1);
    defer conn.deinit();
    conn.protocol = .ndjson;
    conn.ready = true;
    conn.version = 1;
    conn.registry = &registry;
    conn.identity = .{ .principal = g.owner };
    if (with_process) try dispatcher.message(&conn, .{ .ndjson = "{\"id\":0,\"verb\":\"session.create\"}" });
    const high = events.high;
    conn.output.clearRetainingCapacity();
    fault.fail_index = fault.alloc_index + index;
    // The daemon's own launch environment is explicit, never a caller map.
    try dispatcher.message(&conn, .{ .ndjson = if (with_process) "{\"id\":1,\"verb\":\"window.create\",\"params\":{\"session\":\"s0\",\"argv\":[\"true\"],\"cwd\":\"/\",\"env\":[{\"name\":\"A\",\"value\":\"1\"}],\"env_unset\":[\"PATH\"]}}" else "{\"id\":1,\"verb\":\"session.create\"}" });
    fault.fail_index = std.math.maxInt(usize);
    // A discarded child is killed and reaped without blocking the reactor.
    const deadline = streams.nowMs() + 5000;
    while (product.discarded.items.len > 0 and streams.nowMs() < deadline) try product.supervise();
    try testing.expectEqual(@as(usize, 0), product.discarded.items.len);
    const parsed = try std.json.parseFromSlice(Value, testing.allocator, conn.output.items, .{});
    defer parsed.deinit();
    const success = parsed.value.object.contains("ok");
    if (!success) {
        try testing.expectEqual(high, events.high);
        try testing.expectEqual(@as(usize, 0), product.windows.items.len);
        try testing.expectEqual(@as(usize, 0), product.panes.items.len);
        try testing.expectEqual(@as(usize, 0), server.panes.items.len);
        if (!with_process) try testing.expectEqual(@as(usize, 0), product.sessions.items.len);
        for (registry.entries.items[2..]) |entry| try testing.expect(entry.revoked);
    }
    return success;
}

test "a rolled-back spawn after the pane principal is issued publishes no principal event" {
    const testing = std.testing;
    const a = testing.allocator;
    var events = try proto.events.Log.init(a, "venomx", .{}, null);
    defer events.deinit();
    events.catalog = &@import("manifest.zig").catalog;
    var registry = try g.Registry.init(a, "venomx", .{});
    defer registry.deinit();
    var server = streams.Server.init(a, events.source);
    defer server.deinit();
    var leaders = supervisor.Leaders.init(a, .{});
    defer leaders.deinit();
    var product: Product = .{ .a = a, .streams = &server, .registry = &registry, .events = &events, .environ = .empty, .leaders = &leaders };
    defer product.deinit();
    registry.containment = g.Containment.init(&product);
    var emitter: principal_events.Emitter = .{ .events = &events, .registry = &registry };
    defer emitter.deinit();
    registry.observer = emitter.observer();
    product.principals = &emitter;
    const bindings_ = product.bindings() ++ .{proto.Binding{ .verb = "events", .handler = proto.VerbHandler.init(&events) }};
    var dispatcher = try proto.Dispatcher.init(a, &@import("manifest.zig").core_model, &bindings_, .{}, null);
    defer dispatcher.deinit();
    var conn = proto.Connection.init(a, -1);
    defer conn.deinit();
    conn.protocol = .ndjson;
    conn.ready = true;
    conn.version = 1;
    conn.registry = &registry;
    conn.identity = .{ .principal = g.owner };
    try dispatcher.message(&conn, .{ .ndjson = "{\"id\":0,\"verb\":\"session.create\"}" });
    const high = events.high;
    const principals = registry.entries.items.len;
    conn.output.clearRetainingCapacity();
    // The principal is issued before the program is looked up; the missing
    // program rolls the whole spawn back.
    try dispatcher.message(&conn, .{ .ndjson = "{\"id\":1,\"verb\":\"window.create\",\"params\":{\"session\":\"s0\",\"argv\":[\"/nonexistent/prog\"]}}" });
    try testing.expect(std.mem.indexOf(u8, conn.output.items, "unavailable.spawn") != null);
    try testing.expectEqual(high, events.high);
    try testing.expect(registry.entries.items.len > principals);
    for (registry.entries.items[principals..]) |entry| try testing.expect(entry.revoked);
    // A spawn that succeeds announces the principal with the pane.
    conn.output.clearRetainingCapacity();
    try dispatcher.message(&conn, .{ .ndjson = "{\"id\":2,\"verb\":\"window.create\",\"params\":{\"session\":\"s0\",\"argv\":[\"true\"]}}" });
    try testing.expect(std.mem.indexOf(u8, conn.output.items, "\"ok\"") != null);
    const last = events.entries.items[events.entries.items.len - 1];
    try testing.expectEqualStrings("principal.created", last.type);
    const deadline = streams.nowMs() + 5000;
    while (product.discarded.items.len > 0 and streams.nowMs() < deadline) try product.supervise();
}

test "frozen authorization records are freed once no retained event refers to them" {
    const testing = std.testing;
    const a = testing.allocator;
    var events = try proto.events.Log.init(a, "venomx", .{ .count = 2 }, null);
    defer events.deinit();
    events.catalog = &@import("manifest.zig").catalog;
    var registry = try g.Registry.init(a, "venomx", .{});
    defer registry.deinit();
    var server = streams.Server.init(a, events.source);
    defer server.deinit();
    var leaders = supervisor.Leaders.init(a, .{});
    defer leaders.deinit();
    var product: Product = .{ .a = a, .streams = &server, .registry = &registry, .events = &events, .environ = .empty, .leaders = &leaders };
    defer product.deinit();
    registry.containment = g.Containment.init(&product);
    const bindings_ = product.bindings() ++ .{proto.Binding{ .verb = "events", .handler = proto.VerbHandler.init(&events) }};
    var dispatcher = try proto.Dispatcher.init(a, &@import("manifest.zig").core_model, &bindings_, .{}, null);
    defer dispatcher.deinit();
    var conn = proto.Connection.init(a, -1);
    defer conn.deinit();
    conn.protocol = .ndjson;
    conn.ready = true;
    conn.version = 1;
    conn.registry = &registry;
    conn.identity = .{ .principal = g.owner };
    try dispatcher.message(&conn, .{ .ndjson = "{\"id\":0,\"verb\":\"session.create\"}" });
    try dispatcher.message(&conn, .{ .ndjson = "{\"id\":1,\"verb\":\"session.remove\",\"params\":{\"session\":\"s0\"}}" });
    try product.tick();
    // Both of s0's events are retained: its record still resolves ownership.
    try testing.expectEqual(@as(usize, 1), product.removedRecords());
    try testing.expectEqual(g.owner, product.ownerOf(.{ .kind = "session", .id = "s0" }).?);
    // Two newer events push them out of retention; the record goes with them.
    try dispatcher.message(&conn, .{ .ndjson = "{\"id\":2,\"verb\":\"session.create\"}" });
    try dispatcher.message(&conn, .{ .ndjson = "{\"id\":3,\"verb\":\"session.create\"}" });
    try product.tick();
    try testing.expectEqual(@as(usize, 0), product.removedRecords());
    try testing.expect(product.ownerOf(.{ .kind = "session", .id = "s0" }) == null);
    try testing.expectEqual(@as(usize, 2), product.sessions.items.len);
}

test "pane.relaunch under allocation failure leaves the archive intact and leaks no child or principal" {
    var completed = false;
    for (0..4096) |index| {
        if (try relaunchTrial(index)) {
            completed = true;
            break;
        }
    }
    try std.testing.expect(completed);
}
fn relaunchTrial(index: usize) !bool {
    const testing = std.testing;
    var fault = testing.FailingAllocator.init(testing.allocator, .{});
    const a = fault.allocator();
    var events = try proto.events.Log.init(a, "venomx", .{}, null);
    defer events.deinit();
    events.catalog = &@import("manifest.zig").catalog;
    var registry = try g.Registry.init(a, "venomx", .{});
    defer registry.deinit();
    var server = streams.Server.init(a, events.source);
    defer server.deinit();
    var leaders = supervisor.Leaders.init(a, .{});
    defer leaders.deinit();
    var product: Product = .{ .a = a, .streams = &server, .registry = &registry, .events = &events, .environ = .empty, .leaders = &leaders };
    defer product.deinit();
    registry.containment = g.Containment.init(&product);
    const bindings_ = product.bindings() ++ .{proto.Binding{ .verb = "events", .handler = proto.VerbHandler.init(&events) }};
    var dispatcher = try proto.Dispatcher.init(testing.allocator, &@import("manifest.zig").core_model, &bindings_, .{}, null);
    defer dispatcher.deinit();
    var conn = proto.Connection.init(testing.allocator, -1);
    defer conn.deinit();
    conn.protocol = .ndjson;
    conn.ready = true;
    conn.version = 1;
    conn.registry = &registry;
    conn.identity = .{ .principal = g.owner };
    try dispatcher.message(&conn, .{ .ndjson = "{\"id\":0,\"verb\":\"session.create\"}" });
    // An archive as recovery.restore builds it: no PTY, leader or principal.
    const s = product.sessions.items[0];
    const w = try a.create(Window);
    w.* = .{ .id = try product.allocateId('w', &product.next_window), .name = try a.dupe(u8, ""), .session = s, .owner = g.owner, .nodes = undefined };
    const id = try product.allocateId('p', &server.next_pane);
    w.nodes = try a.dupe(Node, &.{.{ .kind = .pane, .pane = id }});
    try product.windows.append(a, w);
    const sp = try stream.Pane.create(a, id, .{ .cols = 30, .rows = 5 }, server.config);
    sp.status = .unknown;
    const ar = try a.create(recovery.Archive);
    ar.* = .{ .checkpoint = @splat('c'), .previous_pane = try a.dupe(u8, "p9"), .process_state = .interrupted, .text = .omitted };
    const x = try a.create(Pane);
    x.* = .{ .id = id, .window = w, .owner = g.owner, .principal = g.unknown, .pane = sp, .archive = ar, .observation = Observation.init(a, &events, id), .exit_published = true };
    try product.panes.append(a, x);
    try server.panes.append(a, sp);
    const high = events.high;
    const principals = registry.entries.items.len;
    conn.output.clearRetainingCapacity();
    fault.fail_index = fault.alloc_index + index;
    try dispatcher.message(&conn, .{ .ndjson = "{\"id\":1,\"verb\":\"pane.relaunch\",\"params\":{\"pane\":\"p0\",\"argv\":[\"true\"],\"ack_orphans\":true}}" });
    fault.fail_index = std.math.maxInt(usize);
    const deadline = streams.nowMs() + 5000;
    while (product.discarded.items.len > 0 and streams.nowMs() < deadline) try product.supervise();
    try testing.expectEqual(@as(usize, 0), product.discarded.items.len);
    const parsed = try std.json.parseFromSlice(Value, testing.allocator, conn.output.items, .{});
    defer parsed.deinit();
    if (!parsed.value.object.contains("ok")) {
        try testing.expectEqual(high, events.high);
        try testing.expect(!x.removed and x.archive != null and !sp.removed);
        try testing.expectEqual(@as(u64, 1), w.revision);
        try testing.expectEqualStrings("p0", w.nodes[0].pane.?);
        try testing.expectEqual(@as(usize, 1), product.panes.items.len);
        try testing.expectEqual(@as(usize, 1), server.panes.items.len);
        for (registry.entries.items[principals..]) |entry| try testing.expect(entry.revoked);
        return false;
    }
    // One commit: archive removal, the new pane, the layout, then the new pane's principal.
    try testing.expectEqual(high + 4, events.high);
    const tail = events.entries.items[events.entries.items.len - 4 ..];
    try testing.expectEqualStrings("pane.removed", tail[0].type);
    try testing.expectEqualStrings("pane.created", tail[1].type);
    try testing.expectEqualStrings("window.layout_changed", tail[2].type);
    try testing.expectEqualStrings("principal.created", tail[3].type);
    try testing.expect(x.removed and sp.removed);
    try testing.expectEqual(@as(u64, 2), w.revision);
    try testing.expectEqualStrings("p1", w.nodes[0].pane.?);
    const fresh = product.pane("p1").?;
    try testing.expect(fresh.archive == null and fresh.principal != g.unknown);
    try testing.expectEqual(@as(u16, 30), fresh.pane.vt.size().cols);
    // A retry names the removed archive; the new pane is not an archive.
    conn.output.clearRetainingCapacity();
    try dispatcher.message(&conn, .{ .ndjson = "{\"id\":2,\"verb\":\"pane.relaunch\",\"params\":{\"pane\":\"p0\",\"argv\":[\"true\"],\"ack_orphans\":true}}" });
    try testing.expect(std.mem.indexOf(u8, conn.output.items, "not_found.pane") != null);
    conn.output.clearRetainingCapacity();
    try dispatcher.message(&conn, .{ .ndjson = "{\"id\":3,\"verb\":\"pane.relaunch\",\"params\":{\"pane\":\"p1\",\"argv\":[\"true\"],\"ack_orphans\":true}}" });
    try testing.expect(std.mem.indexOf(u8, conn.output.items, "conflict.not_archive") != null);
    try testing.expectEqual(high + 4, events.high);
    return true;
}
