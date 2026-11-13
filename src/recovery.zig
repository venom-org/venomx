//! Durable session restore: opt-in checkpoints of
//! session/window/split topology, pane lifecycle and optional plain text, and
//! explicit restore into an empty daemon as inspectable archives. Restore
//! executes and signals zero processes; nothing from disk grants authority.
//!
//! Capture is consistent at one reactor boundary;
//! encoding, the generation scan, publication (temp, fsync, rename, directory
//! fsync) and pruning then run on one writer thread against that immutable
//! view, so PTY processing never waits for the disk. At most one write is in
//! flight: a periodic tick while busy is coalesced into one later capture,
//! and an explicit checkpoint fails `conflict.recovery_busy`.
const std = @import("std");
const c = std.c;
const os = @import("os.zig");
const proto = @import("proto");
const g = proto.grants;
const Vt = @import("vt").Vt;
const xdg = @import("xdg");
const log = @import("log");
const format = @import("recovery_format.zig");
const store_mod = @import("recovery_store.zig");
const Store = store_mod.Store;
const layout = @import("layout.zig");
const floats = @import("floats.zig");
const chrome = @import("chrome.zig");
const stream = @import("stream.zig");
const product_mod = @import("product.zig");
const Product = product_mod.Product;
const Observation = @import("observation.zig").Observation;
const test_seams = @import("build_options").test_seams;
const eq = std.mem.eql;
const Value = std.json.Value;

/// `recovery` config section. Every field reloads live.
pub const Settings = struct {
    enabled: bool = false,
    interval_ms: u32 = 30000,
    max_checkpoints: u32 = 3,
    max_checkpoint_bytes: u32 = 16777216,
    max_age_seconds: u32 = 604800,
    terminal_text: enum { off, plain } = .off,
    text_max_rows: u32 = 10000,
    text_max_bytes: u32 = 1048576,
    text_max_age_seconds: u32 = 86400,
    pub fn check(self: Settings) error{Invalid}!void {
        const ok = self.interval_ms >= 1000 and self.interval_ms <= 3600000 and
            self.max_checkpoints >= 1 and self.max_checkpoints <= 100 and
            self.max_checkpoint_bytes >= 65536 and self.max_checkpoint_bytes <= 67108864 and
            self.max_age_seconds >= 1 and self.max_age_seconds <= 2592000 and
            self.text_max_rows <= 100000 and self.text_max_bytes <= 16777216 and
            self.text_max_age_seconds >= 1 and self.text_max_age_seconds <= 2592000 and
            self.text_max_age_seconds <= self.max_age_seconds;
        if (!ok) return error.Invalid;
    }
    /// Terminal text may be stored or shown under this policy.
    pub fn textAllowed(self: Settings) bool {
        return self.terminal_text == .plain and self.text_max_rows > 0 and self.text_max_bytes > 0;
    }
    fn fileLimit(self: Settings) usize {
        return @min(self.max_checkpoint_bytes, format.hard_max_bytes);
    }
};

/// Per-archive recovery metadata, owned by the product pane record.
pub const Archive = struct {
    checkpoint: format.Id,
    previous_pane: []u8,
    process_state: format.ProcessState,
    text: enum { omitted, expired, plain },
    /// Rows cut during this restore (screen and history combined).
    cut_rows: usize = 0,
    saved_at_ms: i64 = 0,
    expires_at_ms: i64 = 0,
    /// Storage for a historical signal name (the stream status borrows it).
    signal: ?[]u8 = null,
    pub fn destroy(self: *Archive, a: std.mem.Allocator) void {
        a.free(self.previous_pane);
        if (self.signal) |s| a.free(s);
        a.destroy(self);
    }
};
pub const Metadata = struct { checkpoint: []const u8, previous_pane: []const u8, process_state: []const u8, text_state: []const u8, cut_rows: usize };
/// The optional closed `recovery` object on pane.list, pane.capture and
/// pane snapshot content; ordinary live panes omit it.
pub fn metadata(p: *const product_mod.Pane) ?Metadata {
    const x = p.archive orelse return null;
    return .{ .checkpoint = &x.checkpoint, .previous_pane = x.previous_pane, .process_state = @tagName(x.process_state), .text_state = @tagName(x.text), .cut_rows = x.cut_rows };
}

/// Wall clock in ms; the integration seam may offset it (backward clock).
var clock_offset_ms: i64 = 0;
pub fn wallMs() i64 {
    var ts: c.timespec = undefined;
    if (c.clock_gettime(c.CLOCK.REALTIME, &ts) != 0) unreachable;
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(ts.nsec, 1_000_000) + clock_offset_ms;
}
fn monoMs() i64 {
    return proto.os.nowMs();
}
fn random16() [16]u8 {
    var b: [16]u8 = undefined;
    os.randomBytes(&b);
    return b;
}

pub const Status = enum { valid, corrupt, incompatible, expired, unsafe, future };
const Info = struct {
    entry: store_mod.Entry,
    status: Status,
    /// Too large to read under the current bounds (reported as size).
    oversized: bool = false,
    checkpoint: ?format.Checkpoint = null,
    bytes: usize = 0,
    fn generation(self: *const Info) ?u64 {
        return if (self.checkpoint) |cp| cp.generation else null;
    }
    fn hasText(self: *const Info) bool {
        const cp = self.checkpoint orelse return false;
        for (cp.panes) |p| if (p.text == .plain) return true;
        return false;
    }
};
const max_entries = 4096;

pub const Recovery = struct {
    a: std.mem.Allocator,
    product: *Product,
    settings: Settings = .{},
    socket: []u8 = &.{},
    uid: u32,
    /// `$XDG_STATE_HOME` (or `$HOME/.local/state`); null when neither is usable.
    base: ?[]u8 = null,
    key: [64]u8 = undefined,
    store: ?Store = null,
    fault: store_mod.Fault = .none,
    /// Test seam: writer delay before publication (a slow fsync).
    delay_ms: u32 = 0,
    /// The single in-flight write, owned by the reactor until it is settled.
    job: ?*Job = null,
    /// A periodic tick arrived while `job` was in flight.
    coalesced: bool = false,
    /// No automatic write until a product mutation, restore or
    /// explicit checkpoint, so idle startup cannot evict archives.
    activated: bool = false,
    /// Set by any restore; orphan cleanup is never verified.
    cleanup_unverified: bool = false,
    next_due_ms: i64 = 0,
    last_hash: ?[32]u8 = null,
    // Doctor (content-free).
    last_attempt_ms: ?i64 = null,
    last_success_ms: ?i64 = null,
    last_error: ?[]const u8 = null,
    prune_error: ?[]const u8 = null,
    /// Panes whose text was omitted from the latest capture, by reason.
    text_failed: u32 = 0,
    text_over_budget: u32 = 0,
    /// Sticky: when text was last omitted and how many panes then (doctor
    /// keeps showing it after a later good capture).
    last_omit_ms: ?i64 = null,
    last_omit_failed: u32 = 0,
    last_omit_budget: u32 = 0,
    /// Signature of the failing pane set last logged; 0 when none. A
    /// persistent failure logs once, not once per interval.
    omit_sig: u64 = 0,
    /// Daemon logger for one-off events that doctor would not retain.
    logger: ?*log.Logger = null,

    pub fn init(a: std.mem.Allocator, product: *Product, environ: std.process.Environ) !Recovery {
        var self: Recovery = .{ .a = a, .product = product, .uid = c.getuid() };
        errdefer self.deinit();
        self.base = xdg.base(a, .state, .{ .environ = environ, .uid = self.uid }) catch |err| if (err == error.OutOfMemory) return err else null;
        if (test_seams) {
            if (environ.getPosix("VENOMX_TEST_RECOVERY_FAULT")) |v| self.fault = std.meta.stringToEnum(store_mod.Fault, v) orelse .none;
            if (environ.getPosix("VENOMX_TEST_CLOCK_OFFSET_MS")) |v| clock_offset_ms = std.fmt.parseInt(i64, v, 10) catch 0;
            if (environ.getPosix("VENOMX_TEST_RECOVERY_DELAY_MS")) |v| self.delay_ms = std.fmt.parseInt(u32, v, 10) catch 0;
        }
        return self;
    }
    /// Store identity follows the startup socket selection (after the
    /// server resolved and locked it).
    pub fn bind(self: *Recovery, socket: []const u8) !void {
        self.socket = try absoluteSocket(self.a, socket);
        self.key = store_mod.socketKey(self.socket);
    }
    pub fn deinit(self: *Recovery) void {
        // The writer may still hold the store; nobody is left to answer.
        if (self.job) |job| {
            if (job.thread) |th| th.join();
            job.destroy();
            self.job = null;
        }
        if (self.store) |*s| s.close();
        self.store = null;
        if (self.base) |b| self.a.free(b);
        self.a.free(self.socket);
    }
    /// The store, opened once and revalidated on its held handle.
    fn openStore(self: *Recovery, create: bool) store_mod.Error!?*Store {
        if (self.store) |*s| {
            try s.check();
            return s;
        }
        const base = self.base orelse return error.Unsafe;
        self.store = try Store.open(base, &self.key, create) orelse return null;
        self.store.?.fault = self.fault;
        self.store.?.delay_ms = self.delay_ms;
        return &self.store.?;
    }

    // ------------------------------------------------------------ scanning

    fn scan(self: *Recovery, a: std.mem.Allocator, st: *const Store, s: Settings) ![]Info {
        return scanStore(a, st, s, self.socket, self.uid);
    }

    /// Retention for a policy about to become active (config
    /// reload): first waits for an in-flight write, so a checkpoint captured
    /// under the old policy cannot be published after this purge.
    pub fn enforce(self: *Recovery, s: Settings) ?@import("cfg").ActivationFailure {
        self.settle();
        return self.prune(s);
    }
    /// Retention under `s` on the reactor; may run beside the writer, whose
    /// own pruning tolerates files that vanish underneath it.
    fn prune(self: *Recovery, s: Settings) ?@import("cfg").ActivationFailure {
        const st = (self.openStore(false) catch |err| return .{ .reason = if (err == error.Unsafe) .unsafe_store else .io }) orelse return null;
        const pruned = pruneStore(self.a, st, s, self.socket, self.uid);
        if (pruned.set) self.prune_error = pruned.code;
        return pruned.failure;
    }
    /// Startup before readiness: remove safe temporaries, then enforce. A
    /// text policy that cannot be enforced fails initialization.
    pub fn startup(self: *Recovery) !void {
        const st = (self.openStore(false) catch {
            self.prune_error = "unavailable.recovery_io";
            return;
        }) orelse return;
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        if (st.list(arena.allocator(), max_entries)) |entries| {
            for (entries) |e| if (e.kind == .temporary) {
                st.safe(e.slice()) catch continue;
                st.remove(e.slice()) catch {};
            };
        } else |_| {}
        if (self.enforce(self.settings)) |_| {
            if (!self.settings.textAllowed()) return error.RecoveryRetention;
        }
    }

    // ------------------------------------------------------------ capture

    const Note = struct { pane: []const u8, over_budget: bool, err: []const u8 };
    const Captured = struct { cp: format.Checkpoint, hash: [32]u8, notes: []const Note = &.{} };
    /// One consistent view of the resource tree at this reactor boundary.
    /// Everything is copied into `t`: the writer reads it after the reactor
    /// has moved on and may have freed or changed the live records.
    fn capture(self: *Recovery, t: std.mem.Allocator, shutdown: format.Shutdown, now: i64) !Captured {
        const p = self.product;
        var sessions: std.ArrayList(format.SessionRec) = .empty;
        var windows: std.ArrayList(format.WindowRec) = .empty;
        var panes: std.ArrayList(format.PaneRec) = .empty;
        for (p.sessions.items) |s| if (!s.removed) try sessions.append(t, .{ .session = try t.dupe(u8, s.id), .name = try t.dupe(u8, s.name), .on_empty = @fromBackingInt(@intCast(@backingInt(s.on_empty))) });
        for (p.windows.items) |w| if (!w.removed) try windows.append(t, .{ .window = try t.dupe(u8, w.id), .session = try t.dupe(u8, w.session.id), .name = try t.dupe(u8, w.name), .revision = w.revision, .nodes = try dupeNodes(t, w.nodes) });
        const s = self.settings;
        var notes: std.ArrayList(Note) = .empty;
        // Floats keep their placement spec and z (format 2). Popups
        // are never written: they belong to one client.
        for (p.panes.items) |pane| if (!pane.removed and pane.layer != .popup) {
            const sp = pane.pane;
            const size = sp.vt.size();
            var rec: format.PaneRec = .{ .pane = try t.dupe(u8, pane.id), .window = try t.dupe(u8, pane.window.id), .session = try t.dupe(u8, pane.window.session.id), .cols = size.cols, .rows = size.rows, .state = .running, .on_exit = @fromBackingInt(@intCast(@backingInt(pane.on_exit))) };
            // Pane tags, the daemon-set owner included.
            const tags = try t.alloc(chrome.Tag, pane.tags.items.items.len);
            for (pane.tags.items.items, tags) |x, *o| o.* = .{ .key = try t.dupe(u8, x.key), .value = try t.dupe(u8, x.value) };
            rec.tags = tags;
            if (pane.layer == .float) {
                const f = pane.float.?;
                rec.layer = .float;
                rec.float = .{ .preset = if (f.preset) |x| try t.dupe(u8, x) else null, .explicit = try dupeSpec(t, f.explicit), .z = f.z };
            }
            const status = sp.status orelse (if (shutdown == .clean) sp.reaped else null);
            if (status) |st| {
                rec.state = .exited;
                rec.exit = switch (st) {
                    .code => |code| .{ .code = code },
                    .signal => |sig| if (format.signalValid(sig)) .{ .signal = try t.dupe(u8, sig) } else null,
                    .unknown => null,
                };
            }
            if (shutdown == .clean and rec.state == .running) return error.NotClean;
            if (pane.archive) |x| {
                // Recheckpointing keeps the historical state and the text's
                // original timestamps; it never renews expiry.
                rec.previous_state = x.process_state;
                rec.text = switch (x.text) {
                    .omitted => .omitted,
                    .expired => .expired,
                    .plain => if (!s.textAllowed() or now >= x.expires_at_ms or now < x.saved_at_ms) .expired else try self.textOf(t, pane.id, sp, s, x.saved_at_ms, x.expires_at_ms, &notes),
                };
            } else if (s.textAllowed()) {
                rec.text = try self.textOf(t, pane.id, sp, s, 0, 0, &notes);
            }
            try panes.append(t, rec);
        };
        // Change detection ignores identity, time and live-text timestamps.
        const view = try std.json.Stringify.valueAlloc(t, .{ shutdown, sessions.items, windows.items, panes.items }, .{});
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(view, &hash, .{});
        t.free(view);
        for (panes.items) |*rec| if (rec.text == .plain and rec.text.plain.saved_at_ms == 0) {
            rec.text.plain.saved_at_ms = now;
            rec.text.plain.expires_at_ms = now + @as(i64, s.text_max_age_seconds) * 1000;
        };
        return .{ .hash = hash, .notes = notes.items, .cp = .{ .checkpoint = "", .generation = 0, .socket = self.socket, .uid = self.uid, .captured_at_ms = now, .shutdown = shutdown, .sessions = sessions.items, .windows = windows.items, .panes = panes.items } };
    }
    fn dupeSpec(t: std.mem.Allocator, spec: floats.Spec) !floats.Spec {
        var out = spec;
        if (spec.width) |x| out.width = try t.dupe(u8, x);
        if (spec.height) |x| out.height = try t.dupe(u8, x);
        if (spec.title) |x| out.title = try t.dupe(u8, x);
        return out;
    }
    fn dupeNodes(t: std.mem.Allocator, nodes: []const layout.Node) ![]layout.Node {
        const out = try t.dupe(layout.Node, nodes);
        for (out) |*n| if (n.pane) |id| {
            n.pane = try t.dupe(u8, id);
        };
        return out;
    }
    /// A pane whose text cannot be exported (an error, or over
    /// the text budget) is written with its text omitted; topology is never
    /// dropped to fit text. Only allocation failure still aborts the capture.
    /// Omissions are recorded in `notes` and reported by `noteOmissions`.
    fn textOf(self: *Recovery, t: std.mem.Allocator, pane_id: []const u8, sp: *stream.Pane, s: Settings, saved: i64, expires: i64, notes: *std.ArrayList(Note)) error{OutOfMemory}!format.Text {
        return self.plainOf(t, sp, s, saved, expires) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            try notes.append(t, .{ .pane = pane_id, .over_budget = err == error.OverBudget, .err = @errorName(err) });
            return .omitted;
        };
    }
    /// Reactor side of `textOf`: refresh the doctor counters and sticky
    /// record, and log (once per change of the failing pane set, never per
    /// interval; not an event) the panes and reasons.
    fn noteOmissions(self: *Recovery, notes: []const Note, now: i64) void {
        self.text_failed = 0;
        self.text_over_budget = 0;
        var h = std.hash.Wyhash.init(1);
        for (notes) |n| {
            if (n.over_budget) self.text_over_budget += 1 else self.text_failed += 1;
            h.update(n.pane);
            h.update(n.err);
        }
        if (notes.len == 0) {
            self.omit_sig = 0;
            return;
        }
        self.last_omit_ms = now;
        self.last_omit_failed = self.text_failed;
        self.last_omit_budget = self.text_over_budget;
        const sig = h.final() | 1;
        if (sig == self.omit_sig) return;
        self.omit_sig = sig;
        if (self.logger) |l| for (notes) |n| {
            if (n.over_budget) l.warn("recovery pane text over budget; omitted from checkpoint", .{ .pane = n.pane }) else l.warn("recovery text export failed; pane text omitted from checkpoint", .{ .pane = n.pane, .@"error" = n.err });
        };
    }
    fn plainOf(self: *const Recovery, t: std.mem.Allocator, sp: *stream.Pane, s: Settings, saved: i64, expires: i64) !format.Text {
        if (test_seams and self.fault == .text_export) return error.Backend;
        const exported = try sp.vt.exportPlain(t, .{ .max_rows = s.text_max_rows, .max_bytes = s.text_max_bytes }) orelse return error.OverBudget;
        return .{ .plain = .{ .saved_at_ms = saved, .expires_at_ms = expires, .screen = exported.text.screen, .history = exported.text.history } };
    }

    pub const Written = struct { checkpoint: format.Id, generation: u64 };
    pub const WriteError = error{ Disabled, Io, Size, NotClean, Unchanged, Busy, OutOfMemory };

    /// Captures now and prepares a write job; null when a periodic capture
    /// found the tree unchanged.
    fn prepare(self: *Recovery, shutdown: format.Shutdown, periodic: bool) WriteError!?*Job {
        const s = self.settings;
        if (!s.enabled) return error.Disabled;
        const job = try self.a.create(Job);
        job.* = .{ .gpa = self.a, .arena = .init(self.a), .now = wallMs(), .settings = s, .socket = self.socket, .uid = self.uid };
        var keep = false;
        defer if (!keep) job.destroy();
        job.cap = self.capture(job.arena.allocator(), shutdown, job.now) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.NotClean => error.NotClean,
        };
        self.noteOmissions(job.cap.notes, job.now);
        if (periodic and self.last_hash != null and eq(u8, &self.last_hash.?, &job.cap.hash)) return null;
        self.last_attempt_ms = job.now;
        job.store = (self.openStore(true) catch null) orelse {
            self.last_error = "unavailable.recovery_io";
            return error.Io;
        };
        keep = true;
        return job;
    }
    /// Records a finished job's outcome on the reactor (doctor, change
    /// detection, activation, prune status). Idempotent.
    fn record(self: *Recovery, job: *Job) WriteError!Written {
        if (!job.recorded) {
            job.recorded = true;
            if (job.pruned) |pr| if (pr.set) {
                self.prune_error = pr.code;
            };
            if (job.result) |_| {
                self.last_success_ms = job.now;
                self.last_error = null;
                self.last_hash = job.cap.hash;
                self.activated = true;
            } else |err| self.last_error = if (err == error.Size) "unsupported.checkpoint_size" else "unavailable.recovery_io";
        }
        return job.result;
    }
    /// Waits for the in-flight write and records it; its reply, if any, is
    /// left for the next `poll` (never sent from inside another call).
    fn settle(self: *Recovery) void {
        const job = self.job orelse return;
        if (job.thread) |th| th.join();
        job.thread = null;
        _ = self.record(job) catch {};
    }
    /// Reactor turn: finish a completed write and answer its explicit caller.
    fn poll(self: *Recovery) void {
        const job = self.job orelse return;
        if (job.thread != null and !job.done.load(.acquire)) return;
        self.settle();
        self.job = null;
        defer job.destroy();
        const r = job.reply orelse return;
        // A caller that cancelled or disconnected is gone; the write stands.
        const cl = r.dispatcher.get(r.ticket) orelse return;
        answer(cl, job.result) catch {
            if (r.dispatcher.get(r.ticket)) |open| fail(open, "internal") catch {};
        };
    }
    fn answer(cl: *proto.Call, written: WriteError!Written) !void {
        const w = written catch |err| return fail(cl, switch (err) {
            error.Size => "unsupported.checkpoint_size",
            error.OutOfMemory => "internal",
            else => "unavailable.recovery_io",
        });
        return result(cl, .{ .checkpoint = @as([]const u8, &w.checkpoint), .generation = w.generation });
    }
    /// Starts one write on the writer thread. At most one is in flight: a
    /// periodic request while busy is coalesced, an explicit one is Busy.
    fn begin(self: *Recovery, periodic: bool, reply: ?Reply) WriteError!void {
        if (self.job != null) {
            if (!periodic) return error.Busy;
            self.coalesced = true;
            return;
        }
        const job = (try self.prepare(.open, periodic)) orelse return;
        job.reply = reply;
        self.job = job;
        // Without a thread the write still happens, just on this turn.
        job.thread = std.Thread.spawn(.{}, Job.run, .{job}) catch null;
        if (job.thread == null) job.run();
    }
    /// Synchronous checkpoint (shutdown and tests): waits for any in-flight
    /// write first, then captures, writes and records on this thread.
    /// `periodic` skips an unchanged tree.
    pub fn checkpoint(self: *Recovery, shutdown: format.Shutdown, periodic: bool) WriteError!Written {
        self.settle();
        self.poll();
        const job = (try self.prepare(shutdown, periodic)) orelse return error.Unchanged;
        defer job.destroy();
        job.run();
        return self.record(job);
    }

    /// Reactor turn: latch activation, interval checkpoint and pruning,
    /// and discard archived text once it expires.
    pub fn tick(self: *Recovery, settings: Settings) void {
        self.settings = settings;
        self.poll();
        if (self.product.sessions.items.len > 0) self.activated = true;
        const now = monoMs();
        const due = now >= self.next_due_ms;
        if (due) self.next_due_ms = now + settings.interval_ms;
        if (due or (self.coalesced and self.job == null)) {
            self.coalesced = false;
            if (settings.enabled and self.activated) self.begin(true, null) catch {};
            // A started write prunes after it publishes.
            if (due and self.store != null and self.job == null) _ = self.prune(settings);
        }
        const wall = wallMs();
        for (self.product.panes.items) |p| if (p.archive) |x| if (!p.removed and x.text == .plain and (wall >= x.expires_at_ms or wall < x.saved_at_ms or !settings.textAllowed())) {
            const size = p.pane.vt.size();
            const blank = Vt.init(self.a, .{ .cols = size.cols, .rows = size.rows }) catch continue;
            p.pane.vt.deinit();
            p.pane.vt = blank;
            x.text = .expired;
        };
    }
    /// Final clean checkpoint after every supervised group was reaped,
    /// within its own deadline. True when one was written.
    pub fn finalize(self: *Recovery, deadline_ms: i64) !void {
        // An in-flight write finishes first; its success may activate.
        self.settle();
        if (!self.settings.enabled or !self.activated) return;
        _ = self.checkpoint(.clean, false) catch return error.RecoveryFinal;
        if (monoMs() > deadline_ms) return error.RecoveryDeadline;
    }

    // ------------------------------------------------------------ verbs

    pub fn bindings(self: *Recovery) [5]proto.Binding {
        var out: [5]proto.Binding = undefined;
        for (@import("manifest.zig").recovery_verbs, &out) |v, *b| b.* = .{ .verb = v.name, .handler = proto.VerbHandler.init(self) };
        return out;
    }
    fn fail(call_: *proto.Call, code: []const u8) !void {
        return call_.fail(code, code, struct {}{});
    }
    fn result(call_: *proto.Call, value: anytype) !void {
        const bytes = try std.json.Stringify.valueAlloc(call_.arena(), value, .{ .emit_null_optional_fields = false });
        if (bytes.len + call_.id_json.len + 16 > call_.conn.max_frame) return fail(call_, "unsupported.result_size");
        try call_.ok(try std.json.parseFromSliceLeaky(Value, call_.arena(), bytes, .{}));
    }
    pub fn call(self: *Recovery, call_: *proto.Call) anyerror!void {
        self.dispatch(call_) catch |err| switch (err) {
            error.OutOfMemory => try fail(call_, "internal"),
            else => return err,
        };
    }
    fn dispatch(self: *Recovery, cl: *proto.Call) !void {
        const verb = cl.verb.name;
        // Authorization precedes file lookup, state and existence disclosure.
        if (!try self.product.admit(cl, .admin, .{ .kind = "server", .id = "root" })) return;
        const mutating = eq(u8, verb, "recovery.checkpoint") or eq(u8, verb, "recovery.restore");
        if (mutating and self.product.shutting_down) return fail(cl, "unavailable.shutdown");
        if (mutating and !self.settings.enabled) return fail(cl, "unavailable.recovery_disabled");
        if (eq(u8, verb, "recovery.checkpoint")) {
            // At most one write in flight; the reply follows
            // durable publication on a later reactor turn.
            return self.begin(false, .{ .dispatcher = cl.dispatcher, .ticket = cl.ticket }) catch |err| fail(cl, switch (err) {
                error.Busy => "conflict.recovery_busy",
                error.Size => "unsupported.checkpoint_size",
                error.OutOfMemory => return err,
                else => "unavailable.recovery_io",
            });
        }
        const a = cl.arena();
        if (eq(u8, verb, "recovery.list")) {
            _ = self.prune(self.settings);
            const Item = struct { checkpoint: []const u8, status: []const u8, generation: ?u64 = null };
            const st = (self.openStore(false) catch return fail(cl, "unavailable.recovery_io")) orelse return result(cl, .{ .checkpoints = &[_]Item{} });
            const infos = self.scan(a, st, self.settings) catch |err| return if (err == error.OutOfMemory) err else fail(cl, "unavailable.recovery_io");
            const items = try a.alloc(Item, infos.len);
            for (infos, items) |*x, *it| it.* = .{ .checkpoint = x.entry.id(), .status = @tagName(if (x.oversized) Status.corrupt else x.status), .generation = x.generation() };
            return result(cl, .{ .checkpoints = items });
        }
        const id = cl.params.object.get("checkpoint").?.string;
        if (!format.validId(id)) return cl.fail("invalid_params.checkpoint", "invalid checkpoint identifier", .{ .param = "checkpoint" });
        if (eq(u8, verb, "recovery.forget")) {
            const st = (self.openStore(false) catch return fail(cl, "unavailable.recovery_io")) orelse return fail(cl, "not_found.checkpoint");
            const name = try std.fmt.allocPrint(a, "{s}.json", .{id});
            // Corrupt, incompatible, expired or future files are deleted
            // without parsing; unsafe objects are still refused.
            st.safe(name) catch |err| return fail(cl, if (err == error.Missing) "not_found.checkpoint" else "unavailable.recovery_io");
            st.remove(name) catch |err| return fail(cl, if (err == error.Missing) "not_found.checkpoint" else "unavailable.recovery_io");
            st.sync() catch return fail(cl, "unavailable.recovery_io");
            return result(cl, struct {}{});
        }
        if (eq(u8, verb, "recovery.restore") and self.product.liveSessions() != 0) return fail(cl, "conflict.not_empty");
        _ = self.prune(self.settings);
        const st = (self.openStore(false) catch return fail(cl, "unavailable.recovery_io")) orelse return fail(cl, "not_found.checkpoint");
        const infos = self.scan(a, st, self.settings) catch |err| return if (err == error.OutOfMemory) err else fail(cl, "unavailable.recovery_io");
        const info = for (infos) |*x| {
            if (eq(u8, x.entry.id(), id)) break x;
        } else return fail(cl, "not_found.checkpoint");
        if (info.oversized) return fail(cl, "unsupported.checkpoint_size");
        switch (info.status) {
            .valid => {},
            .corrupt => return fail(cl, "conflict.checkpoint_corrupt"),
            .incompatible => return fail(cl, "unsupported.checkpoint_format"),
            .expired, .future => return fail(cl, "conflict.checkpoint_expired"),
            .unsafe => return fail(cl, "unavailable.recovery_io"),
        }
        const cp = info.checkpoint.?;
        if (eq(u8, verb, "recovery.inspect")) {
            var text: usize = 0;
            var expired: usize = 0;
            const now = wallMs();
            for (cp.panes) |p| switch (p.text) {
                .plain => |pl| if (self.textUsable(pl, now) != null) {
                    text += 1;
                } else {
                    expired += 1;
                },
                .expired => expired += 1,
                .omitted => {},
            };
            return result(cl, .{ .checkpoint = id, .generation = cp.generation, .shutdown = @tagName(cp.shutdown), .sessions = cp.sessions.len, .windows = cp.windows.len, .panes = cp.panes.len, .text_panes = text, .expired_text_panes = expired });
        }
        return self.restore(cl, cp);
    }
    /// The text's effective expiry under the current policy, or null when it
    /// must be discarded (expired, backward clock, or text now forbidden).
    fn textUsable(self: *const Recovery, pl: format.Plain, now: i64) ?i64 {
        if (!self.settings.textAllowed() or now < pl.saved_at_ms) return null;
        const limit = @min(pl.expires_at_ms, pl.saved_at_ms + @as(i64, self.settings.text_max_age_seconds) * 1000);
        return if (now >= limit) null else limit;
    }

    // ------------------------------------------------------------ restore

    const Staged = struct {
        sessions: []*product_mod.Session,
        windows: []*product_mod.Window,
        panes: []*product_mod.Pane,
    };
    /// Validate, prepare every resource and event, then commit
    /// in this reactor turn. All-or-nothing; no process is executed or signalled.
    fn restore(self: *Recovery, cl: *proto.Call, cp: format.Checkpoint) !void {
        const p = self.product;
        const ga = self.a;
        const a = cl.arena();
        const principal = cl.conn.identity.principal;
        const now = wallMs();
        var committed = false;
        // Staging; everything below is released unless committed.
        var sessions: std.ArrayList(*product_mod.Session) = .empty;
        defer sessions.deinit(ga);
        var windows: std.ArrayList(*product_mod.Window) = .empty;
        defer windows.deinit(ga);
        var panes: std.ArrayList(*product_mod.Pane) = .empty;
        defer panes.deinit(ga);
        defer if (!committed) {
            for (panes.items) |x| {
                if (x.archive) |ar| ar.destroy(ga);
                if (x.float) |f| f.destroy(ga);
                x.tags.deinit(ga);
                x.observation.deinit();
                x.pane.destroy();
                ga.free(x.id);
                ga.destroy(x);
            }
            for (windows.items) |x| {
                ga.free(x.nodes);
                ga.free(x.id);
                ga.free(x.name);
                ga.destroy(x);
            }
            for (sessions.items) |x| {
                ga.free(x.id);
                ga.free(x.name);
                ga.destroy(x);
            }
        };
        const Map = struct { previous: []const u8, current: []const u8 };
        const smap = try a.alloc(Map, cp.sessions.len);
        const wmap = try a.alloc(Map, cp.windows.len);
        const pmap = try a.alloc(Map, cp.panes.len);
        try sessions.ensureTotalCapacity(ga, cp.sessions.len);
        try windows.ensureTotalCapacity(ga, cp.windows.len);
        try panes.ensureTotalCapacity(ga, cp.panes.len);
        for (cp.sessions, smap) |rec, *m| {
            const x = try ga.create(product_mod.Session);
            errdefer ga.destroy(x);
            const id = try p.allocateId('s', &p.next_session);
            errdefer ga.free(id);
            x.* = .{ .id = id, .name = try ga.dupe(u8, rec.name), .owner = principal, .on_empty = @fromBackingInt(@intCast(@backingInt(rec.on_empty))) };
            sessions.appendAssumeCapacity(x);
            m.* = .{ .previous = rec.session, .current = id };
        }
        // Floats get fresh z-orders above every live one, keeping their saved
        // stacking order (ties: pane order).
        const zs = try a.alloc(u64, cp.panes.len);
        var stacked: std.ArrayList(usize) = .empty;
        for (cp.panes, 0..) |rec, i| if (rec.float != null) try stacked.append(a, i);
        std.sort.pdq(usize, stacked.items, cp.panes, struct {
            fn less(recs: []const format.PaneRec, x: usize, y: usize) bool {
                const zx = recs[x].float.?.z;
                const zy = recs[y].float.?.z;
                return zx < zy or (zx == zy and x < y);
            }
        }.less);
        if (p.floats.next_z > std.math.maxInt(u64) - stacked.items.len) return error.Overflow;
        for (stacked.items, 1..) |i, rank| zs[i] = p.floats.next_z + rank;
        // Panes first: window trees refer to their new record IDs.
        for (cp.panes, pmap, zs) |rec, *m, z| {
            const x = try ga.create(product_mod.Pane);
            errdefer ga.destroy(x);
            const id = try p.allocateId('p', &p.streams.next_pane);
            errdefer ga.free(id);
            const sp = try stream.Pane.create(ga, id, .{ .cols = rec.cols, .rows = rec.rows }, p.streams.config);
            errdefer sp.destroy();
            const ar = try ga.create(Archive);
            errdefer ga.destroy(ar);
            ar.* = .{ .checkpoint = cp.checkpoint[0..37].*, .previous_pane = try ga.dupe(u8, rec.pane), .text = .omitted, .process_state = rec.previous_state orelse if (rec.state == .exited and rec.exit != null) .exited else .interrupted };
            errdefer ga.free(ar.previous_pane);
            errdefer if (ar.signal) |sig| ga.free(sig);
            // A fresh reset terminal at the saved size; plain text is
            // hydrated as literal cells, never parsed as escapes.
            var vt: Vt = undefined;
            switch (rec.text) {
                .omitted => vt = try Vt.init(ga, .{ .cols = rec.cols, .rows = rec.rows }),
                .expired => {
                    ar.text = .expired;
                    vt = try Vt.init(ga, .{ .cols = rec.cols, .rows = rec.rows });
                },
                .plain => |pl| if (self.textUsable(pl, now)) |limit| hydrate: {
                    const report = Vt.fromPlainReport(ga, .{ .cols = rec.cols, .rows = rec.rows, .history = pl.history, .screen = pl.screen }, .{ .scrollback_lines = @max(10_000, pl.history.len), .max_rows = self.settings.text_max_rows, .max_bytes = self.settings.text_max_bytes }) catch |err| {
                        if (err == error.OutOfMemory) return err;
                        // The checkpoint topology is valid even when these
                        // rows cannot hydrate. Keep the default omitted state
                        // and discard this pane's screen and history together.
                        vt = try Vt.init(ga, .{ .cols = rec.cols, .rows = rec.rows });
                        break :hydrate;
                    };
                    vt = report.vt;
                    ar.cut_rows = report.cut_rows;
                    ar.text = .plain;
                    ar.saved_at_ms = pl.saved_at_ms;
                    ar.expires_at_ms = limit;
                } else {
                    ar.text = .expired;
                    vt = try Vt.init(ga, .{ .cols = rec.cols, .rows = rec.rows });
                },
            }
            sp.vt.deinit();
            sp.vt = vt;
            if (rec.exit) |e| switch (e) {
                .code => |code| sp.status = .{ .code = code },
                .signal => |sig| {
                    ar.signal = try ga.dupe(u8, sig);
                    sp.status = .{ .signal = ar.signal.? };
                },
            } else sp.status = .unknown;
            // A float archive stays in its window's float layer; its spec is
            // resolved against the current presets and config.
            const fl: ?*floats.Float = if (rec.float) |fr| try floats.Float.create(ga, fr.preset, fr.explicit) else null;
            errdefer if (fl) |f| f.destroy(ga);
            if (fl) |f| {
                _ = try p.floats.place(f);
                f.z = z;
            }
            // Tags are restored as saved, `owner` included, so products still
            // match their archives; a format-1 archive (no tags) gets the
            // restoring caller's namespace as its owner.
            var tags: chrome.Tags = .{};
            errdefer tags.deinit(ga);
            for (rec.tags) |tag| try tags.put(ga, tag.key, tag.value);
            if (tags.get("owner") == null) try tags.put(ga, "owner", cl.namespace());
            x.* = .{ .id = id, .window = undefined, .owner = principal, .principal = g.unknown, .pane = sp, .archive = ar, .observation = Observation.init(ga, p.events, id), .exit_published = true, .on_exit = @fromBackingInt(@intCast(@backingInt(rec.on_exit))), .layer = if (fl != null) .float else .tile, .float = fl, .tags = tags };
            panes.appendAssumeCapacity(x);
            m.* = .{ .previous = rec.pane, .current = id };
        }
        for (cp.windows, wmap) |rec, *m| {
            const x = try ga.create(product_mod.Window);
            errdefer ga.destroy(x);
            const id = try p.allocateId('w', &p.next_window);
            errdefer ga.free(id);
            const name = try ga.dupe(u8, rec.name);
            errdefer ga.free(name);
            const nodes = try ga.dupe(layout.Node, rec.nodes);
            for (nodes) |*n| if (n.kind == .pane) {
                n.pane = panes.items[indexOf(pmap, n.pane.?)].id;
            };
            const session = sessions.items[indexOf(smap, rec.session)];
            x.* = .{ .id = id, .name = name, .session = session, .owner = principal, .nodes = nodes };
            windows.appendAssumeCapacity(x);
            m.* = .{ .previous = rec.window, .current = id };
        }
        for (cp.panes, panes.items) |rec, x| x.window = windows.items[indexOf(wmap, rec.window)];
        // Events: containers before children, then each archive's exit.
        var batch = try product_mod.Batch.init(p.events);
        defer batch.deinit();
        for (sessions.items) |x| try batch.append(try Product.resourceName(a, "session", x.id), "session.created", .{ .session = x.id, .name = x.name });
        for (windows.items) |x| try batch.append(try Product.resourceName(a, "window", x.id), "window.created", .{ .window = x.id, .session = x.session.id, .name = x.name, .revision = x.revision, .nodes = x.nodes });
        for (panes.items) |x| if (x.float) |f| {
            try batch.append(try Product.resourceName(a, "pane", x.id), "pane.created", .{ .pane = x.id, .session = x.window.session.id, .layer = "float", .window = x.window.id, .float = try f.wire(a), .tags = x.tags.items.items });
        } else try batch.append(try Product.resourceName(a, "pane", x.id), "pane.created", .{ .pane = x.id, .session = x.window.session.id, .tags = x.tags.items.items });
        for (panes.items) |x| try batch.append(try Product.resourceName(a, "pane", x.id), "pane.exited", .{ .pane = x.id, .exit_code = if (x.pane.status.? == .code) @as(?u8, x.pane.status.?.code) else null });
        try batch.append("server:root", "recovery.restored", .{ .checkpoint = cp.checkpoint, .cleanup_unverified = true });
        try batch.reserve();
        try p.sessions.ensureUnusedCapacity(ga, sessions.items.len);
        try p.windows.ensureUnusedCapacity(ga, windows.items.len);
        try p.panes.ensureUnusedCapacity(ga, panes.items.len);
        try p.streams.panes.ensureUnusedCapacity(ga, panes.items.len);
        try result(cl, .{ .checkpoint = cp.checkpoint, .sessions = smap, .windows = wmap, .panes = pmap });
        // The response is queued; from here nothing fails.
        p.sessions.appendSliceAssumeCapacity(sessions.items);
        p.windows.appendSliceAssumeCapacity(windows.items);
        p.panes.appendSliceAssumeCapacity(panes.items);
        for (panes.items) |x| p.streams.panes.appendAssumeCapacity(x.pane);
        p.floats.next_z += stacked.items.len;
        batch.commit();
        committed = true;
        if (sessions.items.len > 0) p.lifecycle.created();
        self.cleanup_unverified = true;
        self.activated = true;
    }
    fn indexOf(map: anytype, previous: []const u8) usize {
        for (map, 0..) |m, i| if (eq(u8, m.previous, previous)) return i;
        unreachable; // the decoder verified every reference
    }

    // ------------------------------------------------------------ doctor

    fn omissionText(r: anytype, self: *const Recovery) ![]const u8 {
        const ms = self.last_omit_ms orelse return "";
        const now = if (self.text_failed + self.text_over_budget > 0) try r.print("; text omitted now: {d} pane(s) export failed, {d} over budget", .{ self.text_failed, self.text_over_budget }) else "";
        return try r.print("{s}; text last omitted at {s} ({d} export failed, {d} over budget)", .{ now, &format.formatTime(ms), self.last_omit_failed, self.last_omit_budget });
    }

    pub fn doctor(self: *Recovery, r: anytype) !void {
        const fix = try r.command("{s} recovery list --json", r.tool);
        const s = self.settings;
        const st_result = self.openStore(false);
        const unsafe = if (st_result) |_| false else |_| true;
        const exists = if (st_result) |st| st != null else |_| false;
        const store_status: @import("cli").doctor.Status = if (!s.enabled) .ok else if (unsafe or self.last_error != null) .fail else .ok;
        try r.add("recovery.store", store_status, try r.print("{s}; store {s} (private 0700/0600, socket-keyed); interval {d} ms, {d} checkpoints, {d} bytes, {d} s; terminal text {s}{s}", .{
            if (s.enabled) "enabled" else "disabled (informational)",
            if (unsafe) "unsafe or unavailable" else if (exists) "present" else "not created",
            s.interval_ms,
            s.max_checkpoints,
            s.max_checkpoint_bytes,
            s.max_age_seconds,
            @tagName(s.terminal_text),
            if (s.textAllowed()) " (sensitive: screen text is stored)" else "",
        }), fix);
        const writes_status: @import("cli").doctor.Status = if (!s.enabled) .ok else if (self.last_error != null) .fail else if (self.text_failed + self.text_over_budget > 0) .warn else .ok;
        try r.add("recovery.writes", writes_status, try r.print("last attempt {s}; last durable success {s}; last error {s}{s}; prune {s}", .{
            if (self.last_attempt_ms) |t| try r.print("{s}", .{&format.formatTime(t)}) else "never",
            if (self.last_success_ms) |t| try r.print("{s}", .{&format.formatTime(t)}) else "never",
            self.last_error orelse "none",
            try omissionText(r, self),
            if (self.prune_error) |e| e else "ok",
        }), fix);
        var valid: usize = 0;
        var invalid: usize = 0;
        var expired: usize = 0;
        var bytes: usize = 0;
        if (exists) {
            var arena = std.heap.ArenaAllocator.init(self.a);
            defer arena.deinit();
            const scanned = self.scan(arena.allocator(), (st_result catch unreachable).?, s);
            if (scanned) |infos| {
                for (infos) |x| {
                    bytes += x.bytes;
                    switch (x.status) {
                        .valid => valid += 1,
                        .expired => expired += 1,
                        else => invalid += 1,
                    }
                }
            } else |err| if (err == error.OutOfMemory) return err;
        }
        try r.add("recovery.checkpoints", if (invalid > 0) .warn else .ok, try r.print("{d} valid, {d} invalid, {d} expired; {d} bytes", .{ valid, invalid, expired, bytes }), fix);
        var archives: usize = 0;
        var cut_rows: usize = 0;
        for (self.product.panes.items) |p| if (!p.removed and p.archive != null) {
            archives += 1;
            cut_rows += p.archive.?.cut_rows;
        };
        try r.add("recovery.archives", if (self.cleanup_unverified or cut_rows > 0) .warn else .ok, try r.print("{d} restored archives; cut_rows={d}; cleanup_unverified={}{s}", .{ archives, cut_rows, self.cleanup_unverified, if (self.cleanup_unverified) ": processes from the previous daemon may survive; inspect outside venomx" else "" }), fix);
    }
};

/// Reads and classifies every final checkpoint, oldest generation first.
/// Pure over the store, so the reactor and the writer may both call it.
fn scanStore(a: std.mem.Allocator, st: *const Store, s: Settings, socket: []const u8, uid: u32) ![]Info {
    const entries = st.list(a, max_entries) catch |err| return if (err == error.OutOfMemory) err else error.StoreFailed;
    var out: std.ArrayList(Info) = .empty;
    const now = wallMs();
    for (entries) |e| if (e.kind == .final) {
        var info: Info = .{ .entry = e, .status = .corrupt };
        const bytes = st.read(a, e.slice(), s.fileLimit()) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.TooLarge => {
                info.oversized = true;
                try out.append(a, info);
                continue;
            },
            error.Missing => continue,
            else => {
                info.status = .unsafe;
                try out.append(a, info);
                continue;
            },
        };
        info.bytes = bytes.len;
        switch (try format.decode(a, bytes, .{ .checkpoint = e.id(), .socket = socket, .uid = uid, .max_bytes = s.fileLimit() })) {
            .bad => |f| switch (f) {
                .corrupt => info.status = .corrupt,
                .incompatible => info.status = .incompatible,
                .size => info.oversized = true,
            },
            .ok => |cp| {
                info.checkpoint = cp;
                info.status = if (cp.captured_at_ms > now) .future else if (now - cp.captured_at_ms > @as(i64, s.max_age_seconds) * 1000) .expired else .valid;
            },
        }
        try out.append(a, info);
    };
    // Duplicate generations are refused rather than guessed.
    for (out.items, 0..) |*x, i| if (x.generation()) |gen| for (out.items, 0..) |*y, j| if (i != j and y.generation() == gen) {
        x.status = .corrupt;
    };
    std.mem.sort(Info, out.items, {}, struct {
        fn lt(_: void, x: Info, y: Info) bool {
            const gx = x.generation();
            const gy = y.generation();
            if (gx != null and gy != null and gx.? != gy.?) return gx.? < gy.?;
            if ((gx == null) != (gy == null)) return gx != null;
            return std.mem.lessThan(u8, x.entry.slice(), y.entry.slice());
        }
    }.lt);
    return out.items;
}

const Pruned = struct {
    failure: ?@import("cfg").ActivationFailure = null,
    /// The doctor prune status to record, when `set`.
    code: ?[]const u8 = null,
    set: bool = true,
};
/// Retention: expired files, text the policy forbids, and
/// valid generations beyond the count. Never touches undecodable files.
/// Files removed concurrently (forget, the other thread's pruning) are fine.
/// Retention is purely by count, age and text policy. It deliberately does
/// not keep an older text-bearing checkpoint alive for a pane whose newest
/// checkpoint had its text omitted (export failed or over budget): that would
/// need per-pane text knowledge of every file and could exceed
/// `max_checkpoints`. The text is not lost while the daemon lives (the pane
/// keeps it in memory and the next successful capture writes it again); it is
/// lost only if the daemon dies after `max_checkpoints` omitted generations.
fn pruneStore(gpa: std.mem.Allocator, st: *const Store, s: Settings, socket: []const u8, uid: u32) Pruned {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const infos = scanStore(arena.allocator(), st, s, socket, uid) catch |err| return .{ .failure = .{ .reason = if (err == error.OutOfMemory) .other else .io }, .set = false };
    var deleted = false;
    var kept: usize = 0;
    var i = infos.len;
    while (i > 0) {
        i -= 1;
        const x = infos[i];
        if (x.checkpoint == null or x.status == .corrupt or x.status == .future) continue;
        const drop = x.status == .expired or (x.hasText() and !s.textAllowed()) or kept >= s.max_checkpoints;
        if (!drop) {
            kept += 1;
            continue;
        }
        st.remove(x.entry.slice()) catch |err| if (err != error.Missing) {
            return .{ .failure = .{ .reason = .io, .partial = deleted }, .code = "unavailable.recovery_io" };
        };
        deleted = true;
    }
    if (deleted) st.sync() catch return .{ .failure = .{ .reason = .io, .partial = true }, .code = "unavailable.recovery_io" };
    return .{};
}

const Reply = struct { dispatcher: *proto.Dispatcher, ticket: proto.Ticket };
/// One checkpoint write: the captured view (in `arena`) plus everything the
/// writer thread needs. The reactor neither reads nor frees it until `done`.
const Job = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    cap: Recovery.Captured = undefined,
    now: i64,
    settings: Settings,
    socket: []const u8,
    uid: u32,
    store: *const Store = undefined,
    reply: ?Reply = null,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    result: Recovery.WriteError!Recovery.Written = error.Io,
    /// Retention after a publication; null when nothing was published.
    pruned: ?Pruned = null,
    recorded: bool = false,

    fn destroy(job: *Job) void {
        job.arena.deinit();
        job.gpa.destroy(job);
    }
    fn run(job: *Job) void {
        job.result = job.write();
        job.done.store(true, .release);
    }
    /// The checkpoint writer: next generation, encode within the file limit,
    /// temp/fsync/rename/directory fsync, then prune.
    fn write(job: *Job) Recovery.WriteError!Recovery.Written {
        const t = job.arena.allocator();
        const s = job.settings;
        const infos = scanStore(t, job.store, s, job.socket, job.uid) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.Io;
        var top: u64 = 0;
        for (infos) |x| if (x.generation()) |gen| {
            top = @max(top, gen);
        };
        if (top >= format.max_safe) return error.Io;
        const id = format.newId(&random16());
        const cp = &job.cap.cp;
        cp.checkpoint = &id;
        cp.generation = top + 1;
        // Text never displaces topology: drop it in reverse pane order.
        var bytes = try format.encode(t, cp.*);
        var i = cp.panes.len;
        while (bytes.len > s.fileLimit()) {
            while (i > 0 and cp.panes[i - 1].text != .plain) i -= 1;
            if (i == 0) return error.Size;
            i -= 1;
            cp.panes[i].text = .omitted;
            t.free(bytes);
            bytes = try format.encode(t, cp.*);
        }
        job.store.publish(&id, &format.newId(&random16()), bytes) catch return error.Io;
        // A prune failure does not undo publication; doctor reports it.
        job.pruned = pruneStore(job.gpa, job.store, s, job.socket, job.uid);
        return .{ .checkpoint = id, .generation = cp.generation };
    }
};

/// SHA-256 input is the absolute socket path with its existing
/// parent directory resolved.
fn absoluteSocket(a: std.mem.Allocator, socket: []const u8) ![]u8 {
    const dir = std.fs.path.dirname(socket) orelse ".";
    const dz = try a.dupeSentinel(u8, dir, 0);
    defer a.free(dz);
    var buf: [4096]u8 = undefined;
    const resolved = c.realpath(dz, &buf) orelse return error.InsecurePath;
    const parent = std.mem.span(resolved);
    return std.fmt.allocPrint(a, "{s}{s}{s}", .{ parent, if (eq(u8, parent, "/")) "" else "/", std.fs.path.basename(socket) });
}

test "recovery: settings ranges and text policy" {
    try (Settings{}).check();
    try std.testing.expect(!(Settings{}).textAllowed());
    try std.testing.expect((Settings{ .terminal_text = .plain }).textAllowed());
    try std.testing.expect(!(Settings{ .terminal_text = .plain, .text_max_rows = 0 }).textAllowed());
    try std.testing.expectError(error.Invalid, (Settings{ .interval_ms = 999 }).check());
    try std.testing.expectError(error.Invalid, (Settings{ .max_checkpoints = 0 }).check());
    try std.testing.expectError(error.Invalid, (Settings{ .max_checkpoint_bytes = 65535 }).check());
    try std.testing.expectError(error.Invalid, (Settings{ .max_age_seconds = 10, .text_max_age_seconds = 11 }).check());
}

test "recovery: restore under allocation failure publishes all or nothing, without leaks" {
    const testing = std.testing;
    var pbuf: [256]u8 = undefined;
    var rnd: [8]u8 = undefined;
    os.randomBytes(&rnd);
    const base = try std.fmt.bufPrint(&pbuf, "/tmp/vx-restore-{s}", .{&std.fmt.bytesToHex(rnd, .lower)});
    defer {
        var cmd: [512]u8 = undefined;
        _ = system(std.fmt.bufPrintSentinel(&cmd, "rm -rf '{s}'", .{base}, 0) catch unreachable);
    }
    const socket = "/tmp/vx-restore.sock";
    const key = store_mod.socketKey(socket);
    var st = (try Store.open(base, &key, true)).?;
    defer st.close();
    const id = format.newId(&@splat(7));
    var screen = [_][]const u8{ "hello ✓", "" };
    var history = [_][]const u8{"older"};
    var panes = [_]format.PaneRec{
        .{ .pane = "p0", .window = "w0", .session = "s0", .cols = 12, .rows = 2, .state = .running, .text = .{ .plain = .{ .saved_at_ms = wallMs() - 1000, .expires_at_ms = wallMs() + 3600_000, .screen = &screen, .history = &history } } },
        .{ .pane = "p1", .window = "w0", .session = "s0", .cols = 12, .rows = 2, .state = .exited, .exit = .{ .signal = "SIGTERM" } },
        // A float archive, restored outside the split tree.
        .{ .pane = "p4", .window = "w0", .session = "s0", .cols = 12, .rows = 2, .state = .running, .layer = .float, .float = .{ .preset = "venom.settings", .explicit = .{ .width = "50%", .title = "log" }, .z = 9 }, .tags = &.{ .{ .key = "owner", .value = "venom" }, .{ .key = "role", .value = "log" } } },
    };
    // A resized split keeps its ratio across restore (format 3).
    const nodes = [_]layout.Node{ .{ .kind = .split, .axis = .rows, .first = 1, .second = 2, .ratio = 7000 }, .{ .kind = .pane, .pane = "p0" }, .{ .kind = .pane, .pane = "p1" } };
    const bytes = try format.encode(testing.allocator, .{ .checkpoint = &id, .generation = 1, .socket = socket, .uid = c.getuid(), .captured_at_ms = wallMs() - 1000, .shutdown = .open, .sessions = &.{ .{ .session = "s0", .name = "a" }, .{ .session = "s3", .name = "empty" } }, .windows = &.{ .{ .window = "w0", .session = "s0", .name = "", .revision = 4, .nodes = &nodes }, .{ .window = "w2", .session = "s3", .name = "e", .revision = 1, .nodes = &.{} } }, .panes = &panes });
    defer testing.allocator.free(bytes);
    try st.publish(&id, &format.newId(&@splat(8)), bytes);
    var completed = false;
    for (0..4096) |index| if (try restoreTrial(base, socket, &id, index)) {
        completed = true;
        break;
    };
    try testing.expect(completed);
}
extern "c" fn system([*:0]const u8) c_int;
fn restoreTrial(base: []const u8, socket: []const u8, id: []const u8, index: usize) !bool {
    const testing = std.testing;
    const servers = @import("server.zig");
    var fault = testing.FailingAllocator.init(testing.allocator, .{});
    const a = fault.allocator();
    var events = try proto.events.Log.init(a, "venomx", .{}, null);
    defer events.deinit();
    events.catalog = &@import("manifest.zig").catalog;
    var registry = try g.Registry.init(a, "venomx", .{});
    defer registry.deinit();
    var server = servers.Server.init(a, events.source);
    defer server.deinit();
    var leaders = @import("supervisor").Leaders.init(a, .{});
    defer leaders.deinit();
    var product: Product = .{ .a = a, .streams = &server, .registry = &registry, .events = &events, .environ = .empty, .leaders = &leaders };
    defer product.deinit();
    registry.containment = g.Containment.init(&product);
    var rec: Recovery = .{ .a = a, .product = &product, .uid = c.getuid(), .base = try a.dupe(u8, base), .socket = try a.dupe(u8, socket), .key = store_mod.socketKey(socket), .settings = .{ .enabled = true, .terminal_text = .plain } };
    defer rec.deinit();
    const bindings = product.bindings() ++ rec.bindings() ++ .{proto.Binding{ .verb = "events", .handler = proto.VerbHandler.init(&events) }};
    var dispatcher = try proto.Dispatcher.init(testing.allocator, &@import("manifest.zig").model, &bindings, .{}, null);
    defer dispatcher.deinit();
    var conn = proto.Connection.init(testing.allocator, -1);
    defer conn.deinit();
    conn.protocol = .ndjson;
    conn.ready = true;
    conn.version = 1;
    conn.registry = &registry;
    conn.identity = .{ .principal = g.owner };
    const high = events.high;
    const request = try std.fmt.allocPrint(testing.allocator, "{{\"id\":1,\"verb\":\"recovery.restore\",\"params\":{{\"checkpoint\":\"{s}\"}}}}", .{id});
    defer testing.allocator.free(request);
    fault.fail_index = fault.alloc_index + index;
    try dispatcher.message(&conn, .{ .ndjson = request });
    fault.fail_index = std.math.maxInt(usize);
    const parsed = try std.json.parseFromSlice(Value, testing.allocator, conn.output.items, .{});
    defer parsed.deinit();
    if (!parsed.value.object.contains("ok")) {
        // Nothing partial is visible: no resources, streams or events.
        try testing.expectEqual(high, events.high);
        try testing.expectEqual(@as(usize, 0), product.sessions.items.len);
        try testing.expectEqual(@as(usize, 0), product.windows.items.len);
        try testing.expectEqual(@as(usize, 0), product.panes.items.len);
        try testing.expectEqual(@as(usize, 0), server.panes.items.len);
        return false;
    }
    try testing.expectEqual(@as(usize, 2), product.liveSessions());
    try testing.expectEqual(@as(usize, 3), server.panes.items.len);
    const p0 = product.panes.items[0];
    const float = product.panes.items[2];
    try testing.expectEqual(@TypeOf(float.layer).float, float.layer);
    try testing.expectEqualStrings("venom.settings", float.float.?.preset.?);
    try testing.expectEqualStrings("log", float.float.?.geometry.title);
    try testing.expectEqual(@as(u64, 1), float.float.?.z);
    // Saved tags come back as saved; an untagged record gets owner.
    try testing.expectEqualStrings("venom", float.tags.get("owner").?);
    try testing.expectEqualStrings("log", float.tags.get("role").?);
    try testing.expectEqualStrings("venomx", p0.tags.get("owner").?);
    try testing.expectEqual(@as(usize, 1), p0.tags.items.items.len);
    try testing.expectEqual(@as(u64, 1), product.floats.next_z);
    try testing.expectEqual(@as(usize, 3), product.windows.items[0].nodes.len);
    try testing.expectEqual(@as(?u16, 7000), product.windows.items[0].nodes[0].ratio);
    try testing.expectEqual(@TypeOf(p0.archive.?.text).plain, p0.archive.?.text);
    try testing.expectEqual(format.ProcessState.interrupted, p0.archive.?.process_state);
    try testing.expect(p0.pane.status.? == .unknown);
    try testing.expectEqualStrings("SIGTERM", product.panes.items[1].pane.status.?.signal);
    try testing.expectEqual(@as(u64, 1), product.windows.items[0].revision);
    const text = try p0.pane.vt.exportRows(testing.allocator, p0.pane.vt.rows().epoch, p0.pane.vt.rows().oldest, p0.pane.vt.rows().end);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "hello ✓") != null and std.mem.indexOf(u8, text, "older") != null);
    // Events: containers first, then each archive's exit, then completion.
    try testing.expectEqual(high + 2 + 2 + 3 + 3 + 1, events.high);
    return true;
}
