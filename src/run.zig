//! Trusted run/wait. A run is a daemon-owned record bound to the
//! pane created by its `run` request; its result comes only from the daemon's
//! own wait status for that pane's leader. OSC
//! 133/7501 observations, screen text and `command.*` events are never an
//! input here. Records live in memory only and die with the daemon.
const std = @import("std");
const proto = @import("proto");
const g = proto.grants;
const Vt = @import("vt").Vt;
const supervisor = @import("supervisor");
const spawn_env = @import("spawn_env.zig");
const product_mod = @import("product.zig");
const Product = product_mod.Product;
const Value = std.json.Value;
const eq = std.mem.eql;
extern "c" fn getentropy(*anyopaque, usize) c_int;

/// The `run` config section.
pub const Settings = struct {
    max_active: u32 = 64,
    retain_count: u32 = 256,
    retain_ms: u32 = 3600000,
    retain_bytes: u32 = 16777216,
    pub fn check(self: Settings) error{Invalid}!void {
        if (self.max_active < 1 or self.max_active > 4096) return error.Invalid;
        if (self.retain_count > 65536) return error.Invalid;
        if (self.retain_ms > 604800000) return error.Invalid;
        if (self.retain_bytes > 1073741824) return error.Invalid;
    }
};

pub const State = enum { running, terminating, completed };
pub const Cause = enum { cancel, deadline, pane_kill, removal, shutdown };
pub const Outcome = enum { succeeded, failed, signaled, terminated };

/// The output tail, in `pane.capture_rows`' row form.
pub const Output = struct {
    screen: []const u8,
    epoch: u64,
    offset: u64,
    cols: u16,
    rows: u16,
    oldest: u64,
    start: u64,
    end: u64,
    complete: bool,
    lines: []const []const u8,
};

pub const Run = struct {
    id: []const u8,
    number: u64,
    key: []const u8,
    /// The resolved principal of the `run` request: key namespace and owner.
    owner: g.Id,
    digest: [32]u8,
    pane: []const u8,
    window: []const u8,
    session: []const u8,
    principal: []const u8,
    pid: i64 = 0,
    shell: bool,
    state: State = .running,
    cause: ?Cause = null,
    outcome: ?Outcome = null,
    exit_code: ?u8 = null,
    signal: ?[]const u8 = null,
    signal_number: u32 = 0,
    /// The supervised reap's wait status, recorded by `Product.supervise`.
    wait: ?supervisor.leaders.Status = null,
    started_wall: i64 = 0,
    completed_wall: i64 = 0,
    started_mono: i64 = 0,
    completed_mono: i64 = 0,
    /// Monotonic ms at which the deadline termination starts.
    deadline: ?i64 = null,
    output_rows: u64,
    output_bytes: u64,
    initial_epoch: u64 = 0,
    output: ?Output = null,
    /// Owns every line of `output`.
    output_buf: []u8 = &.{},
    output_lines: [][]const u8 = &.{},
    /// Evicted, kept only as frozen authorization data for retained events.
    expired: bool = false,

    fn deinit(self: *Run, a: std.mem.Allocator) void {
        self.freeOutput(a);
        for ([_][]const u8{ self.id, self.key, self.pane, self.window, self.session, self.principal }) |s| a.free(s);
        a.destroy(self);
    }
    fn freeOutput(self: *Run, a: std.mem.Allocator) void {
        if (self.output_buf.len > 0) a.free(self.output_buf);
        if (self.output_lines.len > 0) a.free(self.output_lines);
        self.output_buf = &.{};
        self.output_lines = &.{};
        self.output = null;
    }
    fn outputBytes(self: *const Run) usize {
        return self.output_buf.len;
    }
    /// `status`: 0 only for `succeeded`.
    pub fn status(self: *const Run) ?u8 {
        const o = self.outcome orelse return null;
        return switch (o) {
            .succeeded => 0,
            .failed => self.exit_code.?,
            .signaled => @intCast(@min(255, 128 + self.signal_number)),
            .terminated => if (self.cause.? == .deadline) 124 else 125,
        };
    }
};

/// What `run` hands to the shared spawn path.
pub const Start = struct {
    id: []const u8,
    number: u64,
    key: []const u8,
    digest: [32]u8,
    shell: bool,
    deadline_ms: ?i64,
    output_rows: u64,
    output_bytes: u64,
    /// Set by spawn once the record is prepared (before the commit point).
    prepared: ?*Run = null,
};

const Waiter = struct { ticket: proto.Ticket, dispatcher: *proto.Dispatcher, run: *Run, deadline: ?i64, output: bool };

pub const Runs = struct {
    settings: Settings = .{},
    /// Retained records, in ID order.
    records: std.ArrayList(*Run) = .empty,
    /// Evicted records still named by retained events (frozen data).
    tombstones: std.ArrayList(*Run) = .empty,
    waiters: std.ArrayList(Waiter) = .empty,
    next: u64 = 0,
    hmac_key: ?[32]u8 = null,
    /// While set, absent-run authorization uses no containment.
    bypass: bool = false,
    // Doctor counters.
    outcomes: [4]u64 = @splat(0),
    causes: [5]u64 = @splat(0),
    reused: u64 = 0,
    started: u64 = 0,
    evictions: [3]u64 = @splat(0),

    pub fn deinit(self: *Runs, a: std.mem.Allocator) void {
        for (self.records.items) |r| r.deinit(a);
        for (self.tombstones.items) |r| r.deinit(a);
        self.records.deinit(a);
        self.tombstones.deinit(a);
        self.waiters.deinit(a);
        if (self.hmac_key) |*k| std.crypto.secureZero(u8, k);
    }
    pub fn find(self: *const Runs, id: []const u8) ?*Run {
        for (self.records.items) |r| if (eq(u8, r.id, id)) return r;
        return null;
    }
    /// The run (live or tombstoned) named by `run:<id>` for containment.
    pub fn resolve(self: *const Runs, id: []const u8) ?*Run {
        if (self.find(id)) |r| return r;
        if (self.bypass) return null;
        for (self.tombstones.items) |r| if (eq(u8, r.id, id)) return r;
        return null;
    }
    pub fn references(self: *const Runs, pane: []const u8) bool {
        for (self.records.items) |r| if (eq(u8, r.pane, pane)) return true;
        for (self.tombstones.items) |r| if (eq(u8, r.pane, pane)) return true;
        return false;
    }
    pub fn active(self: *const Runs) usize {
        var n: usize = 0;
        for (self.records.items) |r| n += @intFromBool(r.state != .completed);
        return n;
    }
    pub fn retainedBytes(self: *const Runs) usize {
        var n: usize = 0;
        for (self.records.items) |r| n += r.outputBytes();
        return n;
    }
    /// `expired` for well-formed IDs below the counter, else `unknown`.
    fn absentReason(self: *const Runs, id: []const u8) []const u8 {
        if (id.len < 2 or id[0] != 'r' or (id.len > 2 and id[1] == '0')) return "unknown";
        const n = std.fmt.parseInt(u64, id[1..], 10) catch return "unknown";
        return if (n < self.next) "expired" else "unknown";
    }
    pub fn allocate(self: *Runs, a: std.mem.Allocator) !struct { id: []const u8, number: u64 } {
        if (self.next == std.math.maxInt(u64)) return error.Overflow;
        const n = self.next;
        self.next += 1;
        return .{ .id = try std.fmt.allocPrint(a, "r{d}", .{n}), .number = n };
    }
    fn byKey(self: *const Runs, owner: g.Id, key: []const u8) ?*Run {
        for (self.records.items) |r| if (r.owner == owner and eq(u8, r.key, key)) return r;
        return null;
    }
    /// Parameter digest: HMAC-SHA-256 under a per-daemon random key of the
    /// canonical JSON of every parameter (defaults applied) except `source`.
    pub fn digest(self: *Runs, a: std.mem.Allocator, params: Value) ![32]u8 {
        if (self.hmac_key == null) {
            var k: [32]u8 = undefined;
            if (getentropy(&k, k.len) != 0) return error.EntropyUnavailable;
            self.hmac_key = k;
        }
        var out: std.Io.Writer.Allocating = .init(a);
        defer out.deinit();
        try canonical(a, &out.writer, params, true);
        var mac: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, out.written(), &self.hmac_key.?);
        std.crypto.secureZero(u8, out.written());
        return mac;
    }
    /// Prepared before the spawn commit point, so committing cannot fail.
    pub fn prepare(self: *Runs, a: std.mem.Allocator, spec: *const Start, owner: g.Id, pane: []const u8, window: []const u8, session: []const u8, principal: []const u8) !*Run {
        try self.records.ensureUnusedCapacity(a, 1);
        const r = try a.create(Run);
        errdefer a.destroy(r);
        var owned: [6][]const u8 = undefined;
        var n: usize = 0;
        errdefer for (owned[0..n]) |s| a.free(s);
        for ([_][]const u8{ spec.id, spec.key, pane, window, session, principal }) |s| {
            owned[n] = try a.dupe(u8, s);
            n += 1;
        }
        r.* = .{ .id = owned[0], .number = spec.number, .key = owned[1], .owner = owner, .digest = spec.digest, .pane = owned[2], .window = owned[3], .session = owned[4], .principal = owned[5], .shell = spec.shell, .output_rows = spec.output_rows, .output_bytes = spec.output_bytes };
        return r;
    }
    pub fn discard(_: *Runs, a: std.mem.Allocator, r: *Run) void {
        r.deinit(a);
    }
    /// The spawn commit point (no failure): the run exists from here.
    pub fn commit(self: *Runs, r: *Run, spec: *const Start, pid: i64, epoch: u64, now_mono: i64) void {
        r.pid = pid;
        r.initial_epoch = epoch;
        r.started_wall = wallMs();
        r.started_mono = now_mono;
        if (spec.deadline_ms) |d| r.deadline = now_mono + d;
        self.records.appendAssumeCapacity(r);
        self.started += 1;
    }

    /// The run completes in the pane's exit-commit turn. Captures the
    /// output tail from the authoritative Vt at the final pane offset.
    pub fn complete(self: *Runs, a: std.mem.Allocator, r: *Run, vt: Vt, offset: u64, now_mono: i64, events: *proto.events.Log) !void {
        if (r.state == .completed) return;
        var out = try captureTail(a, vt, r.output_rows, r.output_bytes);
        errdefer out.deinit(a);
        const was_terminating = r.state == .terminating;
        var exit_code: ?u8 = null;
        var sig: ?[]const u8 = null;
        var sig_number: u32 = 0;
        if (r.wait) |w| switch (w) {
            .code => |code| exit_code = code,
            .signal => |s| {
                sig = signalName(s.number);
                sig_number = s.number;
            },
        } else sig = "SIGUNKNOWN";
        const outcome: Outcome = if (was_terminating) .terminated else if (exit_code) |code| (if (code == 0) .succeeded else .failed) else .signaled;
        var scratch = std.heap.ArenaAllocator.init(a);
        defer scratch.deinit();
        const resource = try std.fmt.allocPrint(scratch.allocator(), "run:{s}", .{r.id});
        try events.append(resource, "run.completed", .{ .run = r.id, .pane = r.pane, .outcome = @tagName(outcome), .exit_code = exit_code, .signal = sig, .cause = if (r.cause) |c| @as(?[]const u8, @tagName(c)) else null });
        // Committed: nothing below fails.
        r.state = .completed;
        r.outcome = outcome;
        r.exit_code = exit_code;
        r.signal = sig;
        r.signal_number = sig_number;
        r.completed_wall = wallMs();
        r.completed_mono = now_mono;
        r.output_buf = out.buf;
        r.output_lines = out.lines;
        r.output = .{ .screen = out.screen, .epoch = out.epoch, .offset = offset, .cols = out.cols, .rows = out.rows, .oldest = out.oldest, .start = out.start, .end = out.end, .complete = out.epoch == r.initial_epoch and out.oldest == 0 and out.start == 0, .lines = out.lines };
        self.outcomes[@backingInt(outcome)] += 1;
    }

    /// Record the first cause; later requests join without changing it.
    pub fn terminating(self: *Runs, r: *Run, cause: Cause) void {
        if (r.state != .running) return;
        r.state = .terminating;
        r.cause = cause;
        self.causes[@backingInt(cause)] += 1;
    }

    pub fn wait(self: *Runs, a: std.mem.Allocator, c: *proto.Call, r: *Run, deadline: ?i64, output: bool) !void {
        try self.waiters.append(a, .{ .ticket = c.ticket, .dispatcher = c.dispatcher, .run = r, .deadline = deadline, .output = output });
    }
    /// Answers every waiter whose run completed or whose timeout passed;
    /// drops waiters whose call ended (cancel, disconnect, shutdown). A wait
    /// never acts on the run.
    pub fn serve(self: *Runs, source: []const u8, now_mono: i64) void {
        var i: usize = 0;
        while (i < self.waiters.items.len) {
            const w = self.waiters.items[i];
            const open = w.dispatcher.get(w.ticket) orelse {
                _ = self.waiters.swapRemove(i);
                continue;
            };
            if (w.run.state == .completed) {
                _ = self.waiters.swapRemove(i);
                respond(open, source, w.run, w.output) catch {
                    if (w.dispatcher.get(w.ticket)) |still| still.fail("internal", "internal", null) catch {};
                };
                continue;
            }
            if (w.deadline) |d| if (now_mono >= d) {
                _ = self.waiters.swapRemove(i);
                timedOut(open, w.run) catch {
                    if (w.dispatcher.get(w.ticket)) |still| still.fail("internal", "internal", null) catch {};
                };
                continue;
            };
            i += 1;
        }
    }
    /// The earliest waiter or run deadline, for the reactor's poll timeout.
    pub fn nextDeadline(self: *const Runs) ?i64 {
        var best: ?i64 = null;
        for (self.waiters.items) |w| if (w.deadline) |d| {
            best = if (best) |b| @min(b, d) else d;
        };
        for (self.records.items) |r| if (r.state == .running) if (r.deadline) |d| {
            best = if (best) |b| @min(b, d) else d;
        };
        return best;
    }

    /// Eviction, oldest completed first. Emits `run.expired` and frees
    /// the key binding; running records are never evicted.
    pub fn evict(self: *Runs, a: std.mem.Allocator, events: *proto.events.Log, now_mono: i64) !void {
        while (true) {
            var count: usize = 0;
            var bytes: usize = 0;
            var oldest: ?usize = null;
            for (self.records.items, 0..) |r, i| if (r.state == .completed) {
                count += 1;
                bytes += r.outputBytes();
                if (oldest == null or r.completed_mono < self.records.items[oldest.?].completed_mono) oldest = i;
            };
            const index = oldest orelse return;
            const r = self.records.items[index];
            const limit: ?usize = if (count > self.settings.retain_count) 0 else if (now_mono - r.completed_mono >= self.settings.retain_ms) 1 else if (bytes > self.settings.retain_bytes) 2 else null;
            const which = limit orelse return;
            try self.tombstones.ensureUnusedCapacity(a, 1);
            var buf: [64]u8 = undefined;
            const resource = std.fmt.bufPrint(&buf, "run:{s}", .{r.id}) catch unreachable;
            try events.append(resource, "run.expired", .{ .run = r.id });
            _ = self.records.orderedRemove(index);
            r.freeOutput(a);
            r.expired = true;
            self.tombstones.appendAssumeCapacity(r);
            self.evictions[which] += 1;
        }
    }
    /// Frees tombstones no retained event names any more.
    pub fn sweep(self: *Runs, a: std.mem.Allocator, events: *const proto.events.Log) void {
        var i: usize = 0;
        while (i < self.tombstones.items.len) {
            const r = self.tombstones.items[i];
            var buf: [64]u8 = undefined;
            const name = std.fmt.bufPrint(&buf, "run:{s}", .{r.id}) catch unreachable;
            const retained = for (events.entries.items[events.head..]) |e| {
                if (eq(u8, e.resource, name)) break true;
            } else false;
            if (retained) {
                i += 1;
                continue;
            }
            _ = self.tombstones.orderedRemove(i);
            r.deinit(a);
        }
    }

    pub fn appendSnapshot(self: *const Runs, a: std.mem.Allocator, out: *std.ArrayList(proto.events.Entity)) !void {
        for (self.records.items) |r| try out.append(a, .{
            .resource = try std.fmt.allocPrint(a, "run:{s}", .{r.id}),
            .entity_type = "run",
            .content = try std.json.Stringify.valueAlloc(a, .{ .run = r.id, .pane = r.pane, .state = @tagName(r.state), .outcome = if (r.outcome) |o| @as(?[]const u8, @tagName(o)) else null, .exit_code = r.exit_code, .signal = r.signal, .cause = if (r.cause) |c| @as(?[]const u8, @tagName(c)) else null }, .{ .emit_null_optional_fields = false }),
            .event_types = &.{ "run.started", "run.terminating", "run.completed", "run.expired" },
        });
    }
};

/// Key syntax: 1–128 bytes of `[A-Za-z0-9._:-]`.
pub fn validKey(key: []const u8) bool {
    if (key.len == 0 or key.len > 128) return false;
    for (key) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '_' or ch == ':' or ch == '-')) return false;
    return true;
}

/// Canonical JSON: object members sorted by name, no whitespace.
fn canonical(a: std.mem.Allocator, w: *std.Io.Writer, v: Value, top: bool) !void {
    switch (v) {
        .object => |o| {
            const keys = try a.dupe([]const u8, o.keys());
            defer a.free(keys);
            std.mem.sort([]const u8, keys, {}, struct {
                fn less(_: void, x: []const u8, y: []const u8) bool {
                    return std.mem.lessThan(u8, x, y);
                }
            }.less);
            try w.writeByte('{');
            var first = true;
            for (keys) |k| {
                if (top and eq(u8, k, "source")) continue;
                if (!first) try w.writeByte(',');
                first = false;
                try std.json.Stringify.value(k, .{}, w);
                try w.writeByte(':');
                try canonical(a, w, o.get(k).?, false);
            }
            try w.writeByte('}');
        },
        .array => |items| {
            try w.writeByte('[');
            for (items.items, 0..) |item, i| {
                if (i > 0) try w.writeByte(',');
                try canonical(a, w, item, false);
            }
            try w.writeByte(']');
        },
        else => try std.json.Stringify.value(v, .{}, w),
    }
}

const Tail = struct {
    buf: []u8,
    lines: [][]const u8,
    screen: []const u8,
    epoch: u64,
    cols: u16,
    rows: u16,
    oldest: u64,
    start: u64,
    end: u64,
    fn deinit(self: *Tail, a: std.mem.Allocator) void {
        if (self.buf.len > 0) a.free(self.buf);
        if (self.lines.len > 0) a.free(self.lines);
    }
};

fn blank(line: []const u8) bool {
    for (line) |ch| if (ch != ' ') return false;
    return true;
}

/// Rows `[s, e)` of the active screen where `e` is one past the last
/// non-blank row and `s` is the smallest start that keeps at most
/// `max_rows` rows and `max_bytes` bytes of line text. Rows are whole.
pub fn captureTail(a: std.mem.Allocator, vt: Vt, max_rows: u64, max_bytes: u64) !Tail {
    const b = vt.rows();
    const size = vt.size();
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const sa = scratch.allocator();
    var e = b.end;
    const chunk: u64 = 64;
    scan: while (e > b.oldest) {
        const from = if (e - b.oldest > chunk) e - chunk else b.oldest;
        const text = try vt.exportRows(sa, b.epoch, from, e);
        var rows_text: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, text[0 .. text.len - @intFromBool(text.len > 0)], '\n');
        while (it.next()) |line| try rows_text.append(sa, line);
        var k = rows_text.items.len;
        while (k > 0) : (k -= 1) {
            if (!blank(rows_text.items[k - 1])) {
                e = from + k;
                break :scan;
            }
        }
        e = from;
    }
    var s = e;
    var bytes: u64 = 0;
    var kept: std.ArrayList([]const u8) = .empty;
    while (s > b.oldest and kept.items.len < max_rows) {
        const from = if (s - b.oldest > chunk) s - chunk else b.oldest;
        const text = try vt.exportRows(sa, b.epoch, from, s);
        var rows_text: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, text[0 .. text.len - @intFromBool(text.len > 0)], '\n');
        while (it.next()) |line| try rows_text.append(sa, line);
        var k = rows_text.items.len;
        var full = false;
        while (k > 0) : (k -= 1) {
            const line = rows_text.items[k - 1];
            if (kept.items.len >= max_rows or bytes + line.len > max_bytes) {
                full = true;
                break;
            }
            bytes += line.len;
            try kept.append(sa, line);
            s -= 1;
        }
        if (full) break;
    }
    if (max_rows == 0 or max_bytes == 0) {
        kept.items.len = 0;
        s = e;
        bytes = 0;
    }
    const buf = try a.alloc(u8, @intCast(bytes));
    errdefer a.free(buf);
    const lines = try a.alloc([]const u8, kept.items.len);
    var at: usize = 0;
    for (0..kept.items.len) |i| {
        const line = kept.items[kept.items.len - 1 - i];
        @memcpy(buf[at..][0..line.len], line);
        lines[i] = buf[at..][0..line.len];
        at += line.len;
    }
    return .{ .buf = buf, .lines = lines, .screen = @tagName(vt.screen()), .epoch = b.epoch, .cols = size.cols, .rows = size.rows, .oldest = b.oldest, .start = s, .end = e };
}

pub fn signalName(n: u32) []const u8 {
    const names = [_][]const u8{ "SIGUNKNOWN", "SIGHUP", "SIGINT", "SIGQUIT", "SIGILL", "SIGTRAP", "SIGABRT", "SIGBUS", "SIGFPE", "SIGKILL", "SIGUSR1", "SIGSEGV", "SIGUSR2", "SIGPIPE", "SIGALRM", "SIGTERM", "SIGSTKFLT", "SIGCHLD", "SIGCONT", "SIGSTOP", "SIGTSTP", "SIGTTIN", "SIGTTOU", "SIGURG", "SIGXCPU", "SIGXFSZ", "SIGVTALRM", "SIGPROF", "SIGWINCH", "SIGIO", "SIGPWR", "SIGSYS" };
    return if (n < names.len) names[n] else "SIGUNKNOWN";
}

pub fn wallMs() i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(ts.nsec, 1000000);
}
fn formatTs(a: std.mem.Allocator, ms: i64) ![]const u8 {
    var base: [32]u8 = undefined;
    const seconds = try proto.audit.timestamp(@divFloor(ms, 1000), &base);
    return std.fmt.allocPrint(a, "{s}.{d:0>3}Z", .{ seconds[0 .. seconds.len - 1], @as(u64, @intCast(@mod(ms, 1000))) });
}

const Record = struct {
    run: []const u8,
    source: []const u8,
    key: []const u8,
    pane: []const u8,
    window: []const u8,
    session: []const u8,
    principal: []const u8,
    pid: i64,
    shell: bool,
    state: []const u8,
    outcome: ?[]const u8 = null,
    exit_code: ?u8 = null,
    signal: ?[]const u8 = null,
    cause: ?[]const u8 = null,
    status: ?u8 = null,
    started_at: []const u8,
    completed_at: ?[]const u8 = null,
    duration_ms: ?i64 = null,
    output: ?Output = null,
};
pub fn record(a: std.mem.Allocator, source: []const u8, r: *const Run, output: bool) !Record {
    const done = r.state == .completed;
    return .{
        .run = r.id,
        .source = source,
        .key = r.key,
        .pane = r.pane,
        .window = r.window,
        .session = r.session,
        .principal = r.principal,
        .pid = r.pid,
        .shell = r.shell,
        .state = @tagName(r.state),
        .outcome = if (r.outcome) |o| @tagName(o) else null,
        .exit_code = r.exit_code,
        .signal = r.signal,
        .cause = if (r.cause) |c| @tagName(c) else null,
        .status = r.status(),
        .started_at = try formatTs(a, r.started_wall),
        .completed_at = if (done) try formatTs(a, r.completed_wall) else null,
        .duration_ms = if (done) r.completed_mono - r.started_mono else null,
        .output = if (done and output) r.output else null,
    };
}
/// Bounds: a reply over the connection's `max_frame` fails
/// `unsupported.result_size` with its size; it is never truncated.
pub fn sized(c: *proto.Call, value: anytype) !void {
    const bytes = try std.json.Stringify.valueAlloc(c.arena(), value, .{ .emit_null_optional_fields = false });
    const total = bytes.len + c.id_json.len + 16;
    if (total > c.conn.max_frame) return c.fail("unsupported.result_size", "result exceeds max_frame; retry with output=false", .{ .bytes = total });
    try c.ok(try std.json.parseFromSliceLeaky(Value, c.arena(), bytes, .{}));
}
fn respond(c: *proto.Call, source: []const u8, r: *const Run, output: bool) !void {
    return sized(c, try record(c.arena(), source, r, output));
}
pub fn respondRecord(p: *Product, c: *proto.Call, r: *const Run) !void {
    return respond(c, p.events.source, r, true);
}
fn timedOut(c: *proto.Call, r: *const Run) !void {
    var buf: [128]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, "run {s} is still {s}", .{ r.id, @tagName(r.state) }) catch "run is still running";
    return c.fail("timeout.wait", message, .{ .run = r.id, .state = @tagName(r.state) });
}

// ------------------------------------------------------------- verbs

fn str(c: *proto.Call, key: []const u8) ?[]const u8 {
    return if (c.params.object.get(key)) |v| v.string else null;
}
fn invalid(c: *proto.Call, code: []const u8, message: []const u8, param: []const u8, reason: []const u8) !void {
    return c.fail(code, message, .{ .param = param, .reason = reason });
}

/// Dispatch for `run` and `run.*`.
pub fn call(p: *Product, c: *proto.Call) !void {
    const verb = c.verb.name;
    if (eq(u8, verb, "run")) return start(p, c);
    if (eq(u8, verb, "run.list")) return list(p, c);
    const id = str(c, "run").?;
    const live = p.runs.find(id);
    const right: g.Right = if (eq(u8, verb, "run.cancel")) .write else .read;
    // An absent run is covered only by `*`, `run:*` or `run:<id>`.
    p.runs.bypass = live == null;
    const allowed = c.authorize(right, .{ .kind = "run", .id = id });
    p.runs.bypass = false;
    if (!try allowed) return;
    const r = live orelse return c.fail("not_found.run", "no such run", .{ .reason = p.runs.absentReason(id) });
    const output = if (c.params.object.get("output")) |v| v.bool else true;
    if (eq(u8, verb, "run.get")) return respond(c, p.events.source, r, output);
    if (eq(u8, verb, "run.wait")) {
        if (r.state == .completed) return respond(c, p.events.source, r, output);
        const timeout: ?i64 = if (c.params.object.get("timeout_ms")) |v| v.integer else null;
        if (timeout != null and timeout.? == 0) return timedOut(c, r);
        return p.runs.wait(p.a, c, r, if (timeout) |t| p.leaders.now() + t else null, output);
    }
    // run.cancel: a bounded termination of the run's pane.
    if (r.state == .completed) return respond(c, p.events.source, r, true);
    const pane = p.pane(r.pane) orelse return respond(c, p.events.source, r, true);
    if (p.shutting_down or p.lifecycle.stopping()) return c.fail("unavailable.shutdown", "daemon is shutting down", null);
    return p.kill(c, pane, .cancel);
}

fn list(p: *Product, c: *proto.Call) !void {
    const a = c.arena();
    const pane_filter = str(c, "pane");
    if (pane_filter) |pid| {
        if (!try c.authorize(.read, .{ .kind = "pane", .id = pid })) return;
        if (p.pane(pid) == null and !p.runs.references(pid)) return c.fail("not_found.pane", "no such pane", null);
    }
    const key = str(c, "key");
    var after: ?u64 = null;
    if (str(c, "after")) |text| if (text.len >= 2 and text[0] == 'r') {
        after = std.fmt.parseInt(u64, text[1..], 10) catch null;
    };
    const limit: usize = @intCast(if (c.params.object.get("limit")) |v| v.integer else 256);
    var out: std.ArrayList(Record) = .empty;
    var next: ?[]const u8 = null;
    const now_s = g.nowSeconds();
    for (p.runs.records.items) |r| {
        if (after != null and r.number <= after.?) continue;
        if (pane_filter) |pid| if (!eq(u8, r.pane, pid)) continue;
        if (key) |k| if (r.owner != c.conn.identity.principal or !eq(u8, r.key, k)) continue;
        if (!p.registry.allows(c.conn.identity, .read, .{ .kind = "run", .id = r.id }, now_s)) continue;
        if (out.items.len == limit) {
            next = out.items[out.items.len - 1].run;
            break;
        }
        try out.append(a, try record(a, p.events.source, r, false));
    }
    return sized(c, .{ .source = p.events.source, .runs = out.items, .next = next });
}

/// `run`, step by step. The last steps end in the shared pane
/// spawn path, which commits the run with its pane.
fn start(p: *Product, c: *proto.Call) !void {
    const o = &c.params.object;
    const session_id = str(c, "session");
    const pane_id = str(c, "pane");
    // Target form names what to authorize.
    if (session_id == null and pane_id == null) return invalid(c, "invalid_params.target", "give exactly one of session or pane", "session", "missing");
    if (session_id != null and pane_id != null) return invalid(c, "invalid_params.target", "give exactly one of session or pane", "pane", "exclusive");
    // The spawn right on the target, before lookup.
    if (!try c.authorize(.spawn, if (session_id) |s| .{ .kind = "session", .id = s } else .{ .kind = "pane", .id = pane_id.? })) return;
    // Source, then shutdown.
    if (str(c, "source")) |s| if (!eq(u8, s, p.events.source)) return c.fail("conflict.source", "the daemon's event source differs", .{ .source = p.events.source });
    if (p.lifecycle.stopping()) return c.fail("unavailable.shutdown", "daemon is shutting down", null);
    // Delegation is checked by the shared registry when the child
    // principal is issued; it has no side effects there.
    // Remaining parameter rules.
    if (session_id != null and o.get("axis") != null) return invalid(c, "invalid_params.target", "axis is only allowed with pane", "axis", "misplaced");
    if (pane_id != null and o.get("axis") == null) return invalid(c, "invalid_params.target", "axis is required with pane", "axis", "missing");
    if (pane_id != null and o.get("name") != null) return invalid(c, "invalid_params.target", "name is only allowed with session", "name", "misplaced");
    const argv = o.get("argv");
    const shell = str(c, "shell");
    if (argv == null and shell == null) return invalid(c, "invalid_params.command", "give exactly one of argv or shell", "argv", "missing");
    if (argv != null and shell != null) return invalid(c, "invalid_params.command", "give exactly one of argv or shell", "shell", "exclusive");
    if (shell) |text| {
        if (text.len == 0 or text.len > 65536) return invalid(c, "invalid_params.command", "shell must be 1-65536 bytes", "shell", "size");
        if (std.mem.indexOfScalar(u8, text, 0) != null) return invalid(c, "invalid_params.command", "NUL in shell", "shell", "nul");
    }
    const key = str(c, "key").?;
    if (!validKey(key)) return invalid(c, "invalid_params.key", "key must be 1-128 bytes of [A-Za-z0-9._:-]", "key", "syntax");
    if (argv) |v| {
        const items = v.array.items;
        if (items.len == 0 or items[0].string.len == 0) return c.fail("invalid_params.argv", "empty argv", .{ .param = "argv" });
        for (items) |item| if (std.mem.indexOfScalar(u8, item.string, 0) != null) return c.fail("invalid_params.argv", "NUL in argv", .{ .param = "argv" });
    }
    if (str(c, "name")) |name| if (!Product.nameValid(name)) return c.fail("invalid_params.name", "invalid display name", .{ .param = "name" });
    if (str(c, "cwd")) |dir| if (spawn_env.checkCwd(dir)) |reason| return invalid(c, "invalid_params.cwd", "invalid cwd", "cwd", reason);
    if (try spawn_env.check(c.arena(), spawn_env.Request.from(c.params.object))) |f| return p.envInvalid(c, f);
    // Key lookup: a retry with the same parameters returns the same run.
    const digest = try p.runs.digest(c.arena(), c.params);
    const owner = c.conn.identity.principal;
    if (p.runs.byKey(owner, key)) |r| {
        if (!std.crypto.timing_safe.eql([32]u8, r.digest, digest)) return c.fail("conflict.run_key", "key is bound to a run with different parameters", .{ .run = r.id });
        p.runs.reused += 1;
        return sized(c, .{ .run = r.id, .source = p.events.source, .key = r.key, .pane = r.pane, .window = r.window, .session = r.session, .principal = r.principal, .pid = r.pid, .reused = true });
    }
    // Target lookup and state.
    var session_: ?*@TypeOf(p.sessions.items[0].*) = null;
    var source: ?*@TypeOf(p.panes.items[0].*) = null;
    if (session_id) |sid| {
        session_ = p.session(sid) orelse return c.fail("not_found.session", "not_found.session", .{});
        if (session_.?.sealed > 0) return c.fail("conflict.removing", "conflict.removing", .{});
    } else {
        const sp = p.pane(pane_id.?) orelse return c.fail("not_found.pane", "not_found.pane", .{});
        if (sp.sealed > 0) return c.fail("conflict.removing", "conflict.removing", .{});
        if (sp.pane.terminating) return c.fail("conflict.pane_terminating", "conflict.pane_terminating", .{});
        if (sp.pane.status != null) return c.fail("conflict.pane_exited", "pane has exited", .{});
        source = sp;
        session_ = sp.window.session;
    }
    // Limit, then the shared preparation and exec.
    if (p.runs.active() >= p.runs.settings.max_active) return c.fail("unavailable.run_limit", "too many runs not yet completed", .{ .max_active = p.runs.settings.max_active });
    const a = c.arena();
    if (shell) |text| {
        var items = std.json.Array.init(a);
        try items.appendSlice(&.{ .{ .string = "/bin/sh" }, .{ .string = "-c" }, .{ .string = text } });
        try o.put(a, "argv", .{ .array = items });
    }
    if (session_id != null and o.get("name") == null) try o.put(a, "name", .{ .string = "" });
    const allocated = try p.runs.allocate(p.a);
    defer p.a.free(allocated.id);
    var spec: Start = .{
        .id = allocated.id,
        .number = allocated.number,
        .key = key,
        .digest = digest,
        .shell = shell != null,
        .deadline_ms = if (o.get("deadline_ms")) |v| v.integer else null,
        .output_rows = @intCast(o.get("output_rows").?.integer),
        .output_bytes = @intCast(o.get("output_bytes").?.integer),
    };
    return p.spawn(c, session_.?, source, &spec, null);
}

test "status mapping and key syntax" {
    const testing = std.testing;
    var r: Run = .{ .id = "", .number = 0, .key = "", .owner = 0, .digest = undefined, .pane = "", .window = "", .session = "", .principal = "", .shell = false, .output_rows = 0, .output_bytes = 0 };
    try testing.expectEqual(@as(?u8, null), r.status());
    r.outcome = .succeeded;
    r.exit_code = 0;
    try testing.expectEqual(@as(?u8, 0), r.status());
    r.outcome = .failed;
    r.exit_code = 3;
    try testing.expectEqual(@as(?u8, 3), r.status());
    r.outcome = .signaled;
    r.signal_number = 11;
    try testing.expectEqual(@as(?u8, 139), r.status());
    r.signal_number = 200;
    try testing.expectEqual(@as(?u8, 255), r.status());
    r.outcome = .terminated;
    r.cause = .deadline;
    try testing.expectEqual(@as(?u8, 124), r.status());
    r.cause = .cancel;
    try testing.expectEqual(@as(?u8, 125), r.status());
    try testing.expect(validKey("build-1"));
    try testing.expect(validKey("a.b_c:d-E9"));
    try testing.expect(!validKey(""));
    try testing.expect(!validKey("bad key"));
    const long: [129]u8 = @splat('x');
    try testing.expect(!validKey(&long));
    try testing.expect(validKey(long[0..128]));
    try testing.expectEqualStrings("SIGSEGV", signalName(11));
}

test "parameter digest is canonical and ignores source" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var runs: Runs = .{};
    defer runs.deinit(testing.allocator);
    const x = try std.json.parseFromSliceLeaky(Value, a, "{\"key\":\"k\",\"argv\":[\"a\",\"b\"],\"session\":\"s0\",\"source\":\"one\"}", .{});
    const y = try std.json.parseFromSliceLeaky(Value, a, "{\"session\":\"s0\",\"source\":\"two\",\"argv\":[\"a\",\"b\"],\"key\":\"k\"}", .{});
    const z = try std.json.parseFromSliceLeaky(Value, a, "{\"session\":\"s0\",\"argv\":[\"b\",\"a\"],\"key\":\"k\"}", .{});
    try testing.expectEqual(try runs.digest(a, x), try runs.digest(a, y));
    try testing.expect(!std.mem.eql(u8, &(try runs.digest(a, x)), &(try runs.digest(a, z))));
}

test "output tail keeps whole rows within row and byte limits" {
    const testing = std.testing;
    var vt = try Vt.init(testing.allocator, .{ .cols = 6, .rows = 4, .scrollback_lines = 100 });
    defer vt.deinit();
    try vt.feed("one\r\ntwo\r\nthree\r\n");
    var t = try captureTail(testing.allocator, vt, 100, 1000);
    defer t.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), t.lines.len);
    try testing.expectEqualStrings("one   ", t.lines[0]);
    try testing.expectEqual(@as(u64, 0), t.start);
    try testing.expectEqual(t.oldest + 3, t.end);
    var u = try captureTail(testing.allocator, vt, 2, 1000);
    defer u.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), u.lines.len);
    try testing.expectEqualStrings("two   ", u.lines[0]);
    var w = try captureTail(testing.allocator, vt, 100, 13);
    defer w.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), w.lines.len);
    var none = try captureTail(testing.allocator, vt, 0, 1000);
    defer none.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), none.lines.len);
    try testing.expectEqual(none.end, none.start);
}
