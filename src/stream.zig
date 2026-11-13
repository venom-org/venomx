//! Pane state machine. All calls belong to one reactor thread.
//! Frames are generated lazily: one in-flight frame per connection, never a
//! per-client copy of PTY output. Call next only after the prior frame drains.
const std = @import("std");
const Vt = @import("vt").Vt;
const Pty = @import("pty.zig").Pty;
pub const Size = Vt.Size;
pub const capability = "venomx.pane_stream";
pub const Kind = struct {
    pub const attach = 0x100;
    pub const attached = 0x101;
    pub const snapshot = 0x102;
    pub const ready = 0x103;
    pub const pty = 0x104;
    pub const scrollback = 0x105;
    pub const input = 0x106;
    pub const resize = 0x107;
    pub const resync = 0x108;
    pub const exit = 0x109;
};
pub const Policy = enum { latest, smallest, fixed };
pub const Config = struct {
    raw_clipboard: enum { external, off } = .external,
    ring_bytes: usize = 1048576,
    client_backlog_bytes: usize = 1048576,
    size_policy: Policy = .latest,
    fixed_size: Size = .{ .cols = 120, .rows = 40 },
    latest_hold_ms: u32 = 1000,
    resize_coalesce_ms: u32 = 30,
    max_history_rows: u64 = 10000,
    pub fn check(self: Config) !void {
        if (self.ring_bytes < 65536 or self.client_backlog_bytes > self.ring_bytes or self.fixed_size.cols == 0 or self.fixed_size.rows == 0 or self.latest_hold_ms > 10000 or self.resize_coalesce_ms > 10000) return error.InvalidConfig;
    }
};
pub const Mode = enum { emulate, raw };
/// Reactor fairness. PTY bytes are read in one coalesced burst of
/// at most `read_burst` bytes, then emulated in slices that start at
/// `feed_chunk_min` and double up to `feed_chunk_max`, until the pane's
/// per-turn time budget is spent; the rest waits in the pane's backlog for
/// the next turn. Doubling keeps the overshoot near the budget when bytes
/// are slow and the call count low when they are fast. Emulation cost per
/// byte varies by orders of magnitude (short lines, controls, Debug builds),
/// so only a time bound guarantees sockets a turn while `yes` floods.
pub const read_burst = 65536;
pub const feed_chunk_min = 64;
pub const feed_chunk_max = 16384;
pub const service_budget_us = 4000;
/// Largest PTY frame payload, whatever `max_frame` allows. The
/// overflow check runs between frames and a connection's other streams wait
/// behind a frame, so this bounds both for a slow reader: 1 s at 256 KiB/s. It
/// also bounds the send buffer that PTY output leaves on a connection. A pane
/// produces at most `read_burst` per turn, so one stream's frames keep up.
pub const pty_frame_max = 262144;
/// After the leader is reaped, unread output is emulated for at most this
/// long before the exit is published (a kill's time is bounded). It
/// also bounds an escaped descendant that keeps the terminal flooded.
pub const exit_drain_ms = 500;
pub fn nowUs() i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) unreachable;
    return @as(i64, @intCast(ts.sec)) * 1000000 + @divTrunc(ts.nsec, 1000);
}
pub const Format = enum {
    ghostty,
    vt,
    pub fn name(self: Format) []const u8 {
        return if (self == .ghostty) Vt.ghostty_format else "vt";
    }
};
pub const Grants = struct { read: bool = true, write: bool = false };
pub const Resume = struct { source: []const u8, offset: u64 };
pub const Options = struct {
    mode: Mode = .emulate,
    format: Format = .ghostty,
    size: Size = .{ .cols = 80, .rows = 24 },
    history: u64 = 10000,
    claim: bool = true,
    @"resume": ?Resume = null,
    colors: ?Vt.QueryColors = null,
    /// The host's cell size in pixels.
    cell: ?Vt.CellSize = null,
};
pub const OwnedFrame = struct {
    kind: u16,
    payload: []u8,
    pub fn deinit(self: OwnedFrame, a: std.mem.Allocator) void {
        a.free(self.payload);
    }
};
fn json(a: std.mem.Allocator, kind: u16, value: anytype) !OwnedFrame {
    return .{ .kind = kind, .payload = try std.json.Stringify.valueAlloc(a, value, .{ .emit_null_optional_fields = false }) };
}
const Ring = struct {
    bytes: []u8,
    head: u64 = 0,
    tail: u64 = 0,
    fn append(self: *Ring, bytes: []const u8) !void {
        const end = try std.math.add(u64, self.head, bytes.len);
        const keep = @min(bytes.len, self.bytes.len);
        const at: usize = @intCast((end - keep) % self.bytes.len);
        const first = @min(keep, self.bytes.len - at);
        const kept = bytes[bytes.len - keep ..];
        @memcpy(self.bytes[at..][0..first], kept[0..first]);
        @memcpy(self.bytes[0 .. keep - first], kept[first..]);
        self.head = end;
        self.tail = @max(self.tail, end -| self.bytes.len);
    }
    fn copy(self: Ring, at: u64, out: []u8) void {
        std.debug.assert(at >= self.tail and at + out.len <= self.head);
        const start: usize = @intCast(at % self.bytes.len);
        const first = @min(out.len, self.bytes.len - start);
        @memcpy(out[0..first], self.bytes[start..][0..first]);
        @memcpy(out[first..], self.bytes[0 .. out.len - first]);
    }
};
const Marker = struct {
    offset: u64,
    seq: u64,
    size: Size,
    rows: Vt.Rows,
};
/// `unknown`: an interrupted restored archive, whose historical exit was
/// never observed; EXIT then carries neither exit_code nor signal.
pub const Exit = union(enum) { code: u8, signal: []const u8, unknown };
pub const Pane = struct {
    allocator: std.mem.Allocator,
    id: []u8,
    vt: Vt,
    pty: ?Pty = null,
    ring: Ring,
    config: Config,
    markers: std.ArrayList(Marker) = .empty,
    marker_seq: u64 = 0,
    streams: std.ArrayList(*Stream) = .empty,
    input: std.ArrayList(u8) = .empty,
    input_sent: usize = 0,
    callback_failed: bool = false,
    status: ?Exit = null,
    /// A supervised leader's reaped status; becomes `status` once the PTY
    /// output already written has been read, so it precedes EXIT.
    reaped: ?Exit = null,
    /// Input is frozen; query replies still flow.
    terminating: bool = false,
    /// Caller input bytes discarded by the freeze (doctor).
    discarded_input: u64 = 0,
    active: ?*Stream = null,
    active_at: i64 = 0,
    colors_seq: u64 = 0,
    cell_seq: u64 = 0,
    /// The pane's answers to XTVERSION, XTGETTCAP `TN` and the colour
    /// scheme query; `terminfo_name` borrows `terminfo_buf`.
    replies: Vt.Replies = .{ .xtversion = xtversion },
    terminfo_buf: [128]u8 = undefined,
    observers: Vt.Callbacks = .{},
    /// The pane's program rang a BEL since the product's last tick.
    /// An observation: it never carries approval or identity.
    bell_pending: bool = false,
    reset_observer: ?*const fn (?*anyopaque) void = null,
    previous_escape: bool = false,
    last_resize: ?i64 = null,
    pending_size: ?Size = null,
    resync_count: u64 = 0,
    removed: bool = false,
    /// PTY bytes read but not yet emulated (see `service_budget_us`).
    backlog: []u8,
    backlog_start: usize = 0,
    backlog_end: usize = 0,
    /// The last PTY read returned less than a full burst (since the reap,
    /// once `reaped_at` is set).
    drained: bool = false,
    /// When `service` first saw `reaped` (see `exit_drain_ms`).
    reaped_at: ?i64 = null,

    /// Heap allocation keeps the Vt's callback context stable.
    pub fn create(a: std.mem.Allocator, id: []const u8, size: Size, config: Config) !*Pane {
        try config.check();
        const p = try a.create(Pane);
        errdefer a.destroy(p);
        const owned_id = try a.dupe(u8, id);
        errdefer a.free(owned_id);
        const ring = try a.alloc(u8, config.ring_bytes);
        errdefer a.free(ring);
        const backlog = try a.alloc(u8, read_burst);
        errdefer a.free(backlog);
        p.* = .{ .allocator = a, .id = owned_id, .vt = undefined, .ring = .{ .bytes = ring }, .config = config, .backlog = backlog };
        const initial = if (config.size_policy == .fixed) config.fixed_size else size;
        p.vt = try Vt.init(a, .{ .cols = initial.cols, .rows = initial.rows, .scrollback_lines = @import("seam.zig").scrollback_lines orelse (Vt.Options{}).scrollback_lines, .callbacks = .{ .context = p, .write_pty = queryReply, .program_status = programStatus, .semantic_prompt = semanticPrompt, .bell = bell }, .replies = p.replies });
        return p;
    }
    /// The `TERM` the pane's program runs under, for XTGETTCAP `TN`. Longer
    /// than a terminfo name can be, or empty: no answer.
    pub fn setTerminfo(self: *Pane, name: []const u8) !void {
        const n = if (name.len > self.terminfo_buf.len) "" else name;
        @memcpy(self.terminfo_buf[0..n.len], n);
        self.replies.terminfo_name = self.terminfo_buf[0..n.len];
        try self.vt.setReplies(self.replies);
    }
    pub fn destroy(self: *Pane) void {
        std.debug.assert(self.streams.items.len == 0);
        if (self.pty) |*p| p.deinit();
        self.vt.deinit();
        self.allocator.free(self.id);
        self.allocator.free(self.ring.bytes);
        self.allocator.free(self.backlog);
        self.markers.deinit(self.allocator);
        self.streams.deinit(self.allocator);
        self.input.deinit(self.allocator);
        self.allocator.destroy(self);
    }
    /// Config changes sizing on next activity; ring storage changes on next feed.
    pub fn reconfigure(self: *Pane, config: Config) !void {
        try config.check();
        self.config = config;
    }
    pub fn spawn(self: *Pane, argv: [*:null]const ?[*:0]const u8) !void {
        if (self.pty != null or self.status != null) return error.AlreadySpawned;
        self.pty = try Pty.spawn(argv, self.vt.size());
    }
    fn programStatus(ctx: ?*anyopaque, value: Vt.ProgramStatus) void {
        const p: *Pane = @ptrCast(@alignCast(ctx.?));
        if (p.observers.program_status) |cb| cb(p.observers.context, value);
    }
    fn bell(ctx: ?*anyopaque) void {
        const p: *Pane = @ptrCast(@alignCast(ctx.?));
        p.bell_pending = true;
    }
    fn semanticPrompt(ctx: ?*anyopaque, value: Vt.SemanticPrompt) void {
        const p: *Pane = @ptrCast(@alignCast(ctx.?));
        if (p.observers.semantic_prompt) |cb| cb(p.observers.context, value);
    }
    pub fn updateColors(self: *Pane) void {
        var colors: Vt.QueryColors = .{};
        var latest: u64 = 0;
        for (self.streams.items) |client| if (client.grants.write and !client.closed and client.options.colors != null and client.colors_at > latest) {
            colors = client.options.colors.?;
            latest = client.colors_at;
        };
        if (self.active) |active| if (!active.closed) {
            if (active.options.colors) |host| {
                colors.fg = host.fg orelse colors.fg;
                colors.bg = host.bg orelse colors.bg;
                colors.cursor = host.cursor orelse colors.cursor;
            }
        };
        self.vt.setQueryColors(colors);
        // CSI ? 996 n follows the background programs are told (OSC 11).
        const scheme: ?Vt.ColorScheme = if (colors.bg) |bg| (if (luma(bg) < 128) .dark else .light) else null;
        if (scheme != self.replies.color_scheme) {
            self.replies.color_scheme = scheme;
            // Only fails for an over-long name, which setTerminfo refuses.
            self.vt.setReplies(self.replies) catch {};
        }
    }
    fn queryReply(ctx: ?*anyopaque, bytes: []const u8) void {
        const p: *Pane = @ptrCast(@alignCast(ctx.?));
        p.queueInput(bytes) catch {
            p.callback_failed = true;
        };
    }
    pub fn queueInput(self: *Pane, bytes: []const u8) !void {
        // Bounded, ordered queue. Never block output on a program not reading.
        if (self.input.items.len - self.input_sent + bytes.len > 1024 * 1024) return error.InputBacklog;
        if (self.input_sent != 0) {
            const rest = self.input.items[self.input_sent..];
            std.mem.copyForwards(u8, self.input.items, rest);
            self.input.items.len = rest.len;
            self.input_sent = 0;
        }
        try self.input.appendSlice(self.allocator, bytes);
    }
    /// Caller input (pane.send, INPUT frames). Discarded while terminating.
    pub fn userInput(self: *Pane, bytes: []const u8) !void {
        if (self.terminating) {
            self.discarded_input += bytes.len;
            return;
        }
        return self.queueInput(bytes);
    }
    /// Enter `terminating`: queued caller bytes never reach the PTY.
    pub fn freezeInput(self: *Pane) void {
        self.terminating = true;
        self.discarded_input += self.input.items.len - self.input_sent;
        self.input.clearRetainingCapacity();
        self.input_sent = 0;
    }
    pub fn feed(self: *Pane, bytes: []const u8) !void {
        if (self.status != null) return error.Exited;
        if (self.ring.bytes.len != self.config.ring_bytes) {
            const storage = try self.allocator.alloc(u8, self.config.ring_bytes);
            const tail = @max(self.ring.tail, self.ring.head -| storage.len);
            for (tail..self.ring.head) |offset| storage[offset % storage.len] = self.ring.bytes[offset % self.ring.bytes.len];
            self.allocator.free(self.ring.bytes);
            self.ring.bytes = storage;
            self.ring.tail = tail;
        }
        self.updateColors();
        if (self.reset_observer) |reset| {
            // Search ESC with the vectorized std routine. Ordinary output
            // must not pay a per-byte observer/state-store cost. Observe
            // candidate RIS boundaries precisely, including across reads.
            var start: usize = 0;
            if (self.previous_escape and bytes.len > 0 and bytes[0] == 'c') {
                try self.feedReset(bytes[0..1], reset);
                start = 1;
            }
            var search = start;
            while (std.mem.indexOfScalar(u8, bytes[search..], 0x1b)) |found| {
                const escape = search + found;
                if (escape + 1 == bytes.len) break;
                if (bytes[escape + 1] == 'c') {
                    try self.feedReset(bytes[start .. escape + 2], reset);
                    start = escape + 2;
                    search = start;
                } else search = escape + 1;
            }
            if (bytes.len > 0) self.previous_escape = bytes[bytes.len - 1] == 0x1b;
            try self.vt.feed(bytes[start..]);
        } else try self.vt.feed(bytes);
        try self.ring.append(bytes);
        while (self.markers.items.len > 0 and self.markers.items[0].offset < self.ring.tail) _ = self.markers.orderedRemove(0);
        if (self.callback_failed) return error.InputBacklog;
    }
    fn feedReset(self: *Pane, bytes: []const u8, reset: *const fn (?*anyopaque) void) !void {
        try self.vt.feed(bytes[0 .. bytes.len - 1]);
        const epoch = self.vt.rows().epoch;
        try self.vt.feed(bytes[bytes.len - 1 ..]);
        if (self.vt.rows().epoch != epoch) reset(self.observers.context);
    }
    /// PTY output read but not yet emulated: the reactor must not sleep.
    pub fn backlogged(self: *const Pane) bool {
        return self.backlog_start < self.backlog_end and self.pty != null and self.status == null;
    }
    /// Fair bounded PTY work; call even if no clients can write their sockets.
    pub fn service(self: *Pane, now: i64) !void {
        try self.tick(now);
        if (self.pty) |*p| {
            // An exited pane's master is no longer read: an escaped
            // descendant may still hold the terminal open.
            if (self.status != null) return;
            if (self.reaped != null and self.reaped_at == null) {
                self.reaped_at = now;
                // Only a read after the reap shows the PTY drained.
                self.drained = false;
            }
            if (self.backlog_start == self.backlog_end) {
                // A PTY read often returns only 4 KiB even when cat has
                // more ready. Coalesce a bounded burst before emulating.
                self.backlog_start = 0;
                self.backlog_end = 0;
                while (self.backlog_end < self.backlog.len) {
                    const got = try p.read(self.backlog[self.backlog_end..]);
                    if (got == 0) break;
                    self.backlog_end += got;
                }
                self.drained = self.backlog_end < self.backlog.len;
            }
            // Emulate within this pane's time budget, at least one slice
            // per turn, so every pane and socket gets a turn.
            const deadline = nowUs() + service_budget_us;
            var slice: usize = feed_chunk_min;
            while (self.backlog_start < self.backlog_end) {
                const end = @min(self.backlog_end, self.backlog_start + slice);
                const chunk = self.backlog[self.backlog_start..end];
                self.backlog_start = end;
                try self.feed(chunk);
                if (nowUs() >= deadline) break;
                slice = @min(slice * 2, feed_chunk_max);
            }
            if (!p.eof and self.input_sent < self.input.items.len) {
                self.input_sent += try p.write(self.input.items[self.input_sent..]);
                if (self.input_sent == self.input.items.len) {
                    self.input.clearRetainingCapacity();
                    self.input_sent = 0;
                }
            }
            const idle = self.backlog_start == self.backlog_end;
            if (p.supervised) {
                // Reaped: publish once the readable backlog is drained (EOF,
                // or a short read), without waiting on escaped holders, and
                // within exit_drain_ms however slow emulation is.
                if (self.reaped) |status| if ((idle and (p.eof or self.drained)) or now - self.reaped_at.? >= exit_drain_ms) {
                    self.status = status;
                    self.terminating = false;
                    self.input.clearRetainingCapacity();
                    self.input_sent = 0;
                    self.backlog_start = 0;
                    self.backlog_end = 0;
                };
            } else if (idle) if (try p.exited()) |status| {
                const signal = status & 0x7f;
                self.status = if (signal == 0) .{ .code = @intCast((status >> 8) & 255) } else .{ .signal = signalName(signal) };
                self.input.clearRetainingCapacity();
                self.input_sent = 0;
            };
        }
    }
    pub fn tick(self: *Pane, now: i64) !void {
        if (self.status != null) {
            self.pending_size = null;
            return;
        }
        if (self.pending_size) |sz| if (self.last_resize == null or now - self.last_resize.? >= self.config.resize_coalesce_ms) try self.applySize(sz, now);
    }
    fn applySize(self: *Pane, sz: Size, now: i64) !void {
        self.pending_size = null;
        if (std.meta.eql(self.vt.size(), sz)) return;
        try self.markers.ensureUnusedCapacity(self.allocator, 1);
        if (self.pty) |p| if (!p.eof) try p.resize(sz, self.vt.cellSize());
        try self.vt.resize(sz.cols, sz.rows);
        self.last_resize = now;
        self.marker_seq += 1;
        const marker: Marker = .{ .offset = self.ring.head, .seq = self.marker_seq, .size = sz, .rows = self.vt.rows() };
        // Several resizes with no intervening bytes have the same effect as
        // the last one. This also bounds marker memory for idle panes.
        if (self.markers.items.len > 0 and self.markers.items[self.markers.items.len - 1].offset == self.ring.head) {
            self.markers.items[self.markers.items.len - 1] = marker;
        } else try self.markers.append(self.allocator, marker);
    }
    fn desiredSize(self: *Pane, now: i64, force: bool) !void {
        if (self.status != null) return;
        var sz = self.vt.size();
        switch (self.config.size_policy) {
            .fixed => sz = self.config.fixed_size,
            .latest => if (self.active) |s| {
                sz = s.options.size;
            },
            .smallest => {
                var found = false;
                for (self.streams.items) |s| if (s.grants.write and !s.closed) {
                    if (!found) {
                        sz = s.options.size;
                        found = true;
                    } else {
                        sz.cols = @min(sz.cols, s.options.size.cols);
                        sz.rows = @min(sz.rows, s.options.size.rows);
                    }
                };
            },
        }
        if (!force and self.last_resize != null and now - self.last_resize.? < self.config.resize_coalesce_ms) {
            self.pending_size = sz;
        } else try self.applySize(sz, now);
    }
    pub fn activity(self: *Pane, s: *Stream, now: i64) !void {
        if (!s.grants.write) return;
        if (self.active == null or self.active == s or now - self.active_at >= self.config.latest_hold_ms) {
            self.active = s;
            self.active_at = now;
        }
        try self.desiredSize(now, false);
        try self.updateCell();
    }
    /// The cell size of the active writer, else of the most recent writer
    /// that sent one, into the Vt and the PTY.
    pub fn updateCell(self: *Pane) !void {
        var cell: Vt.CellSize = .{};
        var latest: u64 = 0;
        for (self.streams.items) |client| if (client.grants.write and !client.closed and client.options.cell != null and client.cell_at > latest) {
            cell = client.options.cell.?;
            latest = client.cell_at;
        };
        if (self.active) |active| if (!active.closed) if (active.options.cell) |c| {
            cell = c;
        };
        if (std.meta.eql(cell, self.vt.cellSize())) return;
        try self.vt.setCellSize(cell);
        if (self.pty) |p| if (!p.eof) try p.resize(self.vt.size(), cell);
    }
};
/// XTVERSION's answer: `venomx <version>`, as `venomx --version` prints.
pub const xtversion = "venomx " ++ @import("version.zig").version;
/// Rec. 601 luma, 0 to 255.
fn luma(rgb: [3]u8) u32 {
    return (@as(u32, rgb[0]) * 299 + @as(u32, rgb[1]) * 587 + @as(u32, rgb[2]) * 114) / 1000;
}
pub fn signalName(sig: u32) []const u8 {
    return switch (sig) {
        1 => "SIGHUP",
        2 => "SIGINT",
        3 => "SIGQUIT",
        6 => "SIGABRT",
        9 => "SIGKILL",
        11 => "SIGSEGV",
        13 => "SIGPIPE",
        15 => "SIGTERM",
        else => "SIGUNKNOWN",
    };
}

pub const Stream = struct {
    pane: *Pane,
    source: []const u8,
    grants: Grants,
    options: Options,
    send_offset: u64,
    marker_seq: u64,
    resumed: bool,
    snap: u32 = 0,
    snap_offset: u64 = 0,
    ready: Vt.Ready = undefined,
    snapshot: ?Vt.SnapshotStream = null,
    replay: ?Vt.VtReplay = null,
    prefix_at: usize = 0,
    history_left: u64 = 0,
    history_end: u64 = 0,
    history_done: bool = false,
    exit_sent: bool = false,
    phase: enum { attached, prepare, snapshot, ready, live, resync, closed } = .attached,
    reason: []const u8 = "requested",
    failure: ?[]const u8 = null,
    closed: bool = false,
    last_snapshot: ?i64 = null,
    colors_at: u64 = 0,
    cell_at: u64 = 0,
    published_input: bool = false,
    published_clipboard: bool = false,

    pub fn create(p: *Pane, source: []const u8, options: Options, grants: Grants, now: i64) !*Stream {
        if (!grants.read) return error.DeniedRead;
        if (options.size.cols == 0 or options.size.rows == 0) return error.InvalidSize;
        const s = try p.allocator.create(Stream);
        errdefer p.allocator.destroy(s);
        const resumed = if (options.@"resume") |r| std.mem.eql(u8, source, r.source) and r.offset >= p.ring.tail and r.offset <= p.ring.head else false;
        s.* = .{ .pane = p, .source = source, .grants = grants, .options = options, .send_offset = if (resumed) options.@"resume".?.offset else p.ring.head, .marker_seq = if (resumed) 0 else p.marker_seq, .resumed = resumed };
        if (options.colors != null and grants.write) {
            p.colors_seq += 1;
            s.colors_at = p.colors_seq;
        }
        if (options.cell != null and grants.write) s.noteCell();
        // Never retain a borrowed JSON resume source.
        s.options.@"resume" = null;
        try p.streams.append(p.allocator, s);
        errdefer _ = p.streams.pop();
        errdefer if (p.active == s) {
            p.active = null;
        };
        if (options.claim) try p.activity(s, now) else if (p.config.size_policy == .smallest and grants.write) try p.desiredSize(now, false);
        try p.updateCell();
        return s;
    }
    /// This stream just sent a cell size: it is now the most recent one.
    pub fn noteCell(self: *Stream) void {
        self.pane.cell_seq += 1;
        self.cell_at = self.pane.cell_seq;
    }
    fn clearSnapshot(self: *Stream) void {
        if (self.snapshot) |*s| s.deinit(self.pane.allocator);
        if (self.replay) |s| s.deinit(self.pane.allocator);
        self.snapshot = null;
        self.replay = null;
    }
    pub fn destroy(self: *Stream) void {
        const p = self.pane;
        self.clearSnapshot();
        for (p.streams.items, 0..) |s, i| if (s == self) {
            _ = p.streams.orderedRemove(i);
            break;
        };
        if (p.active == self) p.active = null;
        p.allocator.destroy(self);
        // The cell size falls back to another writer's; best effort, as a
        // failed TIOCSWINSZ only leaves the old pixel size.
        p.updateCell() catch {};
    }
    pub fn inputBytes(self: *Stream, bytes: []const u8, now: i64) !void {
        if (!self.grants.write) {
            self.failure = "denied.write";
            self.closed = true;
            return;
        }
        if (self.pane.status != null) return;
        // Apply held geometry before input, then serialize this complete frame.
        try self.pane.activity(self, now);
        try self.pane.desiredSize(now, true);
        try self.pane.userInput(bytes);
    }
    pub fn viewport(self: *Stream, sz: Size, now: i64) !void {
        if (sz.cols == 0 or sz.rows == 0) return error.InvalidSize;
        self.options.size = sz;
        if (self.grants.write) try self.pane.desiredSize(now, false);
    }
    pub fn requestResync(self: *Stream) void {
        if (self.phase != .live) return;
        self.reason = "requested";
        self.phase = .resync;
    }
    fn prepare(self: *Stream, now: i64) !void {
        const p = self.pane;
        self.clearSnapshot();
        self.prefix_at = 0;
        self.history_done = false;
        self.exit_sent = false;
        self.history_left = @min(self.options.history, p.config.max_history_rows);
        if (self.options.format == .ghostty) {
            self.snapshot = try p.vt.streamSnapshot(p.allocator);
            self.ready = self.snapshot.?.ready;
            self.snap_offset = p.ring.head;
        } else {
            self.replay = try p.vt.vtSnapshot(p.allocator, .{ .history = if (self.options.mode == .raw) self.history_left else 0 });
            self.snap_offset = p.ring.head - self.replay.?.unfinished;
            // A continuation older than the ring cannot be replayed exactly.
            if (self.snap_offset < p.ring.tail) {
                self.clearSnapshot();
                return error.SnapshotUnavailable;
            }
            const r = p.vt.rows();
            const sz = p.vt.size();
            self.ready = .{ .epoch = r.epoch, .oldest = r.oldest, .top = r.active, .active = r.active, .cols = sz.cols, .rows = sz.rows };
        }
        self.history_end = self.ready.top;
        self.send_offset = self.snap_offset;
        self.marker_seq = p.marker_seq;
        self.snap += 1;
        self.last_snapshot = now;
        self.phase = .snapshot;
    }
    /// A returned frame owns its payload. No frame means idle or throttled.
    pub fn next(self: *Stream, max_frame: usize, now: i64) anyerror!?OwnedFrame {
        const p = self.pane;
        const a = p.allocator;
        if (max_frame < 4096) return error.InvalidFrameLimit;
        if (self.failure) |code| {
            self.failure = null;
            self.phase = .closed;
            self.clearSnapshot();
            return try json(a, 3, .{ .code = code, .message = code });
        }
        if (self.closed) return null;
        if (self.phase == .live and (self.published_input != self.grants.write or
            (self.options.mode == .raw and self.published_clipboard != (p.config.raw_clipboard == .external))))
        {
            // Publish changed filtering permissions before any further PTY
            // bytes. RESYNC's optional metadata is ignored by older clients.
            self.reason = "policy_changed";
            self.phase = .resync;
        }
        switch (self.phase) {
            .closed => return null,
            .attached => {
                self.phase = if (self.resumed) .live else .prepare;
                self.history_done = self.resumed;
                self.published_input = self.grants.write;
                self.published_clipboard = p.config.raw_clipboard == .external;
                return try json(a, Kind.attached, .{ .source = self.source, .pane = p.id, .mode = @tagName(self.options.mode), .format = self.options.format.name(), .resumed = self.resumed, .offset = if (self.resumed) @as(?u64, self.send_offset) else null, .input = self.grants.write, .raw_clipboard = @tagName(p.config.raw_clipboard), .size = p.vt.size(), .policy = @tagName(p.config.size_policy) });
            },
            .prepare => {
                self.prepare(now) catch |err| {
                    if (err == error.SnapshotUnavailable) return null;
                    return err;
                };
                return self.next(max_frame, now);
            },
            .resync => {
                if (std.mem.eql(u8, self.reason, "overflow") and self.last_snapshot != null and now - self.last_snapshot.? < 1000) return null;
                self.clearSnapshot();
                self.phase = .prepare;
                p.resync_count += 1;
                self.published_input = self.grants.write;
                self.published_clipboard = p.config.raw_clipboard == .external;
                return try json(a, Kind.resync, .{ .reason = self.reason, .snap = self.snap + 1, .offset = self.send_offset, .input = self.grants.write, .raw_clipboard = @tagName(p.config.raw_clipboard) });
            },
            .snapshot => {
                const bytes = if (self.snapshot) |s| s.prefix else self.replay.?.bytes;
                const n = @min(max_frame - 12, bytes.len - self.prefix_at);
                const payload = try a.alloc(u8, 12 + n);
                std.mem.writeInt(u32, payload[0..4], self.snap, .big);
                std.mem.writeInt(u64, payload[4..12], self.snap_offset, .big);
                @memcpy(payload[12..], bytes[self.prefix_at..][0..n]);
                self.prefix_at += n;
                if (self.prefix_at == bytes.len) self.phase = .ready;
                return .{ .kind = Kind.snapshot, .payload = payload };
            },
            .ready => {
                self.phase = .live;
                const r = self.ready;
                return try json(a, Kind.ready, .{ .snap = self.snap, .offset = self.snap_offset, .epoch = r.epoch, .oldest = r.oldest, .top = r.top, .active = r.active, .cols = r.cols, .rows = r.rows });
            },
            .live => {},
        }
        if (self.send_offset < p.ring.tail or p.ring.head - self.send_offset > p.config.client_backlog_bytes) {
            self.reason = "overflow";
            self.phase = .resync;
            return self.next(max_frame, now);
        }
        var marker: ?Marker = null;
        for (p.markers.items) |m| if (m.seq > self.marker_seq and m.offset >= self.send_offset) {
            marker = m;
            break;
        };
        if (marker) |m| if (m.offset == self.send_offset) {
            self.marker_seq = m.seq;
            return try json(a, Kind.resize, .{ .offset = m.offset, .cols = m.size.cols, .rows = m.size.rows, .epoch = m.rows.epoch, .oldest = m.rows.oldest, .active = m.rows.active });
        };
        const end = if (marker) |m| m.offset else p.ring.head;
        if (self.send_offset < end) {
            const n: usize = @intCast(@min(end - self.send_offset, @min(max_frame, pty_frame_max) - 8));
            const bytes = try a.alloc(u8, n + 8);
            std.mem.writeInt(u64, bytes[0..8], self.send_offset, .big);
            p.ring.copy(self.send_offset, bytes[8..]);
            self.send_offset += n;
            return .{ .kind = Kind.pty, .payload = bytes };
        }
        if (p.status) |status| if (!self.exit_sent) {
            self.exit_sent = true;
            return switch (status) {
                .code => |code| try json(a, Kind.exit, .{ .offset = p.ring.head, .exit_code = code }),
                .signal => |sig| try json(a, Kind.exit, .{ .offset = p.ring.head, .signal = sig }),
                .unknown => try json(a, Kind.exit, .{ .offset = p.ring.head }),
            };
        };
        if (!self.history_done) {
            const aborted = p.vt.rows().epoch != self.ready.epoch;
            if (aborted or self.options.mode == .raw or self.snapshot == null or self.history_left == 0 or self.history_end <= self.ready.oldest) return try self.endHistory(aborted);
            if (try self.snapshot.?.nextHistory(max_frame - 21)) |chunk| {
                // A ghostty record cannot be split. Termination is preferable
                // to emitting an oversized frame or exceeding the row budget.
                if (chunk.bytes.len > max_frame - 21 or chunk.rows > self.history_left) return try self.endHistory(false);
                const frame = try self.historyFrame(chunk.bytes, chunk.end_row, chunk.rows, if (chunk.last) 1 else 0);
                self.history_left -= chunk.rows;
                self.history_end = chunk.end_row - chunk.rows;
                if (chunk.last) {
                    self.history_done = true;
                    self.clearSnapshot();
                }
                return frame;
            }
            return try self.endHistory(false);
        }
        return null;
    }
    fn historyFrame(self: *Stream, bytes: []const u8, end: u64, rows: u32, flags: u8) !OwnedFrame {
        const epoch = std.math.cast(u32, self.ready.epoch) orelse return error.EpochOverflow;
        const payload = try self.pane.allocator.alloc(u8, 21 + bytes.len);
        std.mem.writeInt(u32, payload[0..4], self.snap, .big);
        std.mem.writeInt(u32, payload[4..8], epoch, .big);
        std.mem.writeInt(u64, payload[8..16], end, .big);
        std.mem.writeInt(u32, payload[16..20], rows, .big);
        payload[20] = flags;
        @memcpy(payload[21..], bytes);
        return .{ .kind = Kind.scrollback, .payload = payload };
    }
    fn endHistory(self: *Stream, aborted: bool) !OwnedFrame {
        const f = try self.historyFrame("", self.history_end, 0, if (aborted) 3 else 1);
        self.history_done = true;
        self.clearSnapshot();
        return f;
    }
};

test "ring bulk copies preserve wrap, oversized writes and absolute offsets" {
    const a = std.testing.allocator;
    const storage = try a.alloc(u8, 7);
    defer a.free(storage);
    var ring: Ring = .{ .bytes = storage };
    try ring.append("abcde");
    try ring.append("fgh");
    var out: [7]u8 = undefined;
    ring.copy(1, &out);
    try std.testing.expectEqualStrings("bcdefgh", &out);
    try ring.append("0123456789");
    try std.testing.expectEqual(@as(u64, 18), ring.head);
    try std.testing.expectEqual(@as(u64, 11), ring.tail);
    ring.copy(11, &out);
    try std.testing.expectEqualStrings("3456789", &out);
    var subset: [3]u8 = undefined;
    ring.copy(13, &subset);
    try std.testing.expectEqualStrings("567", &subset);
}
