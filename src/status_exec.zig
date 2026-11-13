//! Exec sources: a command from the config files whose stdout
//! becomes a segment's text. Each run is its own process group, adopted by
//! the daemon's `supervisor.Leaders` (the only code that waits on it), and
//! a stream source is restarted with the venom-std supervisor's backoff
//! policy, from 1 s to 60 s.
//!
//! The child runs argv directly (no shell), with stdin from the null device,
//! stderr on the daemon's log, the cwd at `$HOME`, and the daemon's base
//! environment (no `*_TOKEN`, no `VENOMX_*`, no token-shaped
//! value) plus `VENOMX_SEGMENT=<id>`. It gets no venomx token.
const std = @import("std");
const proto = @import("proto");
const supervisor = @import("supervisor");
const chrome = @import("chrome.zig");
const spawn_env = @import("spawn_env.zig");
const product_mod = @import("product.zig");
const Product = product_mod.Product;
const Leader = supervisor.Leader;
const c = std.c;
const eq = std.mem.eql;

pub const max_sources = 16;
pub const max_line = 4096;
pub const max_text = 256;
pub const min_every_ms = 1000;
pub const max_every_ms = 86400000;
/// Stream sources restart after 1 s, doubling to 60 s; a run that lasted
/// 10 s counts as healthy again.
pub const restart_policy: supervisor.Policy = .{ .restart = .always, .initial_ms = 1000, .max_ms = 60000, .reset_after_ms = 10000 };
/// Stream lines are coalesced like rule firings (at most 10 per second).
pub const coalesce_ms = 100;

/// `.exec` of a config segment entry (venom-term's `chrome.status.Exec`):
/// `argv` with no shell, `argv[0]` looked up in PATH; interval mode when
/// `every_ms` is set, stream mode otherwise.
pub const ExecConfig = @import("term_chrome").status.Exec;
pub fn validExec(self: ExecConfig) bool {
    if (self.argv.len == 0 or self.argv.len > 64) return false;
    for (self.argv) |x| if (x.len == 0 or x.len > 4096 or std.mem.indexOfScalar(u8, x, 0) != null) return false;
    if (self.every_ms) |ms| if (ms < min_every_ms or ms > max_every_ms) return false;
    return true;
}

/// Why the last run failed, for `doctor`.
pub const Failure = union(enum) { exit: u8, signal: u32, overrun, spawn };

pub const Source = struct {
    /// Owns `entry`'s strings (a deep copy).
    arena: std.heap.ArenaAllocator,
    entry: chrome.SegmentEntry,
    /// ZON of the entry, to tell a changed config entry from the same one.
    key: []const u8,
    leader: ?*Leader = null,
    /// The read end of the child's stdout; -1 when closed.
    fd: c.fd_t = -1,
    partial: std.ArrayList(u8) = .empty,
    /// An over-long line is being skipped up to its newline.
    skipping: bool = false,
    /// Interval mode: the newest complete line of the current run.
    last_line: ?[]u8 = null,
    started_ms: i64 = 0,
    /// Interval: when the next run is due. Stream: when to restart.
    next_ms: i64 = 0,
    /// Consecutive failed runs (stream backoff, doctor).
    failures: u32 = 0,
    overrun: bool = false,
    runs: u64 = 0,
    failed_runs: u64 = 0,
    last_failure: ?Failure = null,
    /// What the segment shows; a JSON line may set style and icon too.
    text: ?[]u8 = null,
    style: ?chrome.Style = null,
    icon: ?[]u8 = null,
    /// A text change waiting for its coalescing window.
    dirty: bool = false,
    last_publish: i64 = std.math.minInt(i64),

    fn every(self: *const Source) ?u32 {
        return self.entry.exec.?.every_ms;
    }
    fn closeFd(self: *Source) void {
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
    }
    fn destroy(self: *Source, gpa: std.mem.Allocator) void {
        self.closeFd();
        self.partial.deinit(gpa);
        if (self.last_line) |x| gpa.free(x);
        if (self.text) |x| gpa.free(x);
        if (self.icon) |x| gpa.free(x);
        self.arena.deinit();
        gpa.destroy(self);
    }
};

pub const Sources = struct {
    items: std.ArrayList(*Source) = .empty,
    /// Leaders still adopted are killed by `Leaders.deinit`.
    pub fn deinit(self: *Sources, a: std.mem.Allocator) void {
        for (self.items.items) |s| s.destroy(a);
        self.items.deinit(a);
    }
};

// ----------------------------------------------------------------- config

/// Starts, restarts and stops sources to match `.status.segments`. A new
/// `argv` or `every_ms` restarts the source; a change to slot fields only
/// (side, priority, style, group, icon, click, …) keeps the process running
/// and republishes the segment. A removed entry is stopped and its segment
/// cleared (`status.cleared`, reason `exec`).
pub fn configure(p: *Product, entries: []const chrome.SegmentEntry) !void {
    const sources = &p.chrome.exec;
    var scratch = std.heap.ArenaAllocator.init(p.a);
    defer scratch.deinit();
    const sa = scratch.allocator();
    var i: usize = 0;
    while (i < sources.items.items.len) {
        const s = sources.items.items[i];
        const same: ?*const chrome.SegmentEntry = for (entries) |*e| {
            if (e.exec == null or !eq(u8, e.id, s.entry.id)) continue;
            break if (eq(u8, try execKey(sa, e.exec.?), try execKey(sa, s.entry.exec.?))) e else null;
        } else null;
        if (same) |e| {
            if (!eq(u8, try entryKey(sa, e.*), s.key)) try reslot(p, s, e.*);
            i += 1;
            continue;
        }
        _ = sources.items.orderedRemove(i);
        stop(p, s);
    }
    for (entries) |e| {
        const ex = e.exec orelse continue;
        if (!validExec(ex) or !std.mem.startsWith(u8, e.id, "user.") or !chrome.validSegmentId(e.id)) continue;
        if (find(p, e.id) != null) continue;
        if (sources.items.items.len >= max_sources) break;
        try sources.items.ensureUnusedCapacity(p.a, 1);
        const s = try p.a.create(Source);
        s.* = .{ .arena = .init(p.a), .entry = undefined, .key = "" };
        errdefer s.destroy(p.a);
        s.entry = try cloneEntry(s.arena.allocator(), e);
        s.key = try entryKey(s.arena.allocator(), e);
        s.next_ms = chrome.nowMs();
        sources.items.appendAssumeCapacity(s);
    }
}
/// Takes a changed entry's slot fields without restarting the run.
fn reslot(p: *Product, s: *Source, e: chrome.SegmentEntry) !void {
    var arena: std.heap.ArenaAllocator = .init(p.a);
    errdefer arena.deinit();
    const entry = try cloneEntry(arena.allocator(), e);
    const key = try entryKey(arena.allocator(), e);
    s.arena.deinit();
    s.arena = arena;
    s.entry = entry;
    s.key = key;
    if (p.chrome.segment(e.id) != null) s.dirty = true;
}
fn execKey(a: std.mem.Allocator, x: ExecConfig) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try std.zon.stringify.serialize(x, .{}, &out.writer);
    return out.written();
}
fn find(p: *Product, id: []const u8) ?*Source {
    for (p.chrome.exec.items.items) |s| if (eq(u8, s.entry.id, id)) return s;
    return null;
}
fn entryKey(a: std.mem.Allocator, e: chrome.SegmentEntry) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try std.zon.stringify.serialize(e, .{}, &out.writer);
    return out.written();
}
fn cloneEntry(a: std.mem.Allocator, e: chrome.SegmentEntry) !chrome.SegmentEntry {
    // A ZON round trip deep-copies every string into the arena.
    const text = try entryKey(a, e);
    return parseZon(chrome.SegmentEntry, a, text);
}

/// Ends a source: its run is terminated (the leader is released once
/// reaped) and its segment cleared.
fn stop(p: *Product, s: *Source) void {
    if (s.leader) |l| {
        if (p.leaders.terminate(l, .{ .signal = .TERM, .deadline = p.leaders.now() + 1000 })) |r| switch (r) {
            .started, .joined => |id| _ = p.leaders.cancel(id),
            .already_exited => {},
        } else |_| _ = c.kill(-l.pid, .KILL);
        p.discarded.append(p.a, l) catch {};
        s.leader = null;
    }
    chrome.unpublish(p, s.entry.id, "exec");
    s.destroy(p.a);
}

/// Shutdown: exec runs stop with the daemon.
pub fn shutdown(p: *Product, deadline: i64) void {
    for (p.chrome.exec.items.items) |s| if (s.leader) |l| if (l.phase != .exited) {
        if (p.leaders.terminate(l, .{ .signal = .HUP, .deadline = deadline })) |r| switch (r) {
            .started, .joined => |id| _ = p.leaders.cancel(id),
            .already_exited => {},
        } else |_| _ = c.kill(-l.pid, .KILL);
    };
}

// ------------------------------------------------------------------- turn

/// One reactor turn: read output, start due runs, kill overrunning ones and
/// publish coalesced text.
pub fn tick(p: *Product) !void {
    const now = chrome.nowMs();
    for (p.chrome.exec.items.items) |s| {
        try drain(p, s);
        if (s.leader) |l| {
            // A run still going at the next tick is killed.
            if (s.every() != null and !s.overrun and now >= s.next_ms and l.phase == .running) {
                s.overrun = true;
                if (p.leaders.terminate(l, .{ .signal = .KILL, .deadline = p.leaders.now() })) |r| switch (r) {
                    .started, .joined => |id| _ = p.leaders.cancel(id),
                    .already_exited => {},
                } else |_| {}
            }
        } else if (now >= s.next_ms and !p.shutting_down) {
            start(p, s, now);
        }
        if (s.dirty and now -| s.last_publish >= coalesce_ms) try publish(p, s, now);
    }
}

/// `Product.supervise`'s hook for a reaped leader; true when it was one of
/// ours.
pub fn exited(p: *Product, l: *Leader) bool {
    const s = for (p.chrome.exec.items.items) |s| {
        if (s.leader == l) break s;
    } else return false;
    drain(p, s) catch {};
    s.closeFd();
    s.leader = null;
    const status = l.status;
    p.leaders.release(l) catch {};
    const now = chrome.nowMs();
    const failure: ?Failure = if (s.overrun) .overrun else if (status) |st| switch (st) {
        .code => |code| if (code == 0) null else Failure{ .exit = code },
        .signal => |sig| Failure{ .signal = sig.number },
    } else null;
    s.overrun = false;
    if (failure) |f| {
        s.failed_runs += 1;
        s.failures +|= 1;
        s.last_failure = f;
    }
    if (s.every() != null) {
        // The last complete line of a successful run is the new text; a
        // failed run keeps the previous text.
        if (failure == null) {
            s.failures = 0;
            s.last_failure = null;
            if (s.last_line) |last| accept(p, s, last);
        }
        if (s.last_line) |x| p.a.free(x);
        s.last_line = null;
    } else {
        // Stream mode: lines read with the exit are shown first, then the
        // segment goes and the command is restarted.
        if (s.dirty) publish(p, s, now) catch {};
        if (failure == null) s.failures +|= 1;
        if (now - s.started_ms >= restart_policy.reset_after_ms) s.failures = 1;
        s.next_ms = now + restart_policy.delay(s.failures);
        if (s.text) |x| p.a.free(x);
        s.text = null;
        s.dirty = false;
        chrome.unpublish(p, s.entry.id, "exec");
    }
    return true;
}

fn start(p: *Product, s: *Source, now: i64) void {
    s.runs += 1;
    s.started_ms = now;
    if (s.every()) |ms| s.next_ms = now + ms;
    spawn(p, s) catch {
        s.failed_runs += 1;
        s.failures +|= 1;
        s.last_failure = .spawn;
        if (s.every() == null) s.next_ms = now + restart_policy.delay(s.failures);
    };
}

extern "c" fn setpgid(pid: c.pid_t, pgid: c.pid_t) c_int;
extern "c" fn execve([*:0]const u8, [*:null]const ?[*:0]const u8, [*:null]const ?[*:0]const u8) c_int;
extern "c" fn chdir([*:0]const u8) c_int;

fn spawn(p: *Product, s: *Source) !void {
    const base = try p.baseEnv();
    var scratch: spawn_env.Scratch = .{ .a = p.a };
    defer scratch.deinit();
    var env: std.ArrayList([*:0]const u8) = .empty;
    defer env.deinit(p.a);
    try env.appendSlice(p.a, base.entries);
    try env.append(p.a, try scratch.printZ("VENOMX_SEGMENT={s}", .{s.entry.id}));
    const envp = try scratch.pointers(env.items);
    const argv_in = s.entry.exec.?.argv;
    var args: std.ArrayList([*:0]const u8) = .empty;
    defer args.deinit(p.a);
    for (argv_in) |x| try args.append(p.a, try scratch.printZ("{s}", .{x}));
    const argv = try scratch.pointers(args.items);
    const candidates = try spawn_env.candidates(&scratch, argv_in[0], base.get("PATH") orelse base.default_path);
    const home = try scratch.printZ("{s}", .{base.get("HOME") orelse "/"});
    var pipe: [2]c.fd_t = undefined;
    if (c.pipe(&pipe) != 0) return error.SystemResources;
    var parent_done = false;
    defer if (!parent_done) {
        _ = c.close(pipe[0]);
    };
    defer _ = c.close(pipe[1]);
    const flags = c.fcntl(pipe[0], c.F.GETFL);
    const nb: c_int = @bitCast(@as(c.O, .{ .NONBLOCK = true }));
    if (flags < 0 or c.fcntl(pipe[0], c.F.SETFL, flags | nb) < 0) return error.SystemResources;
    for (pipe) |fd| if (c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)) < 0) return error.SystemResources;
    const null_fd = c.open("/dev/null", .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (null_fd < 0) return error.SystemResources;
    defer _ = c.close(null_fd);
    const pid = c.fork();
    if (pid < 0) return error.SystemResources;
    if (pid == 0) {
        // Own process group (also set by the parent, whichever runs first),
        // so `Leaders` signals exactly this run.
        _ = setpgid(0, 0);
        _ = c.dup2(null_fd, 0);
        _ = c.dup2(pipe[1], 1);
        _ = chdir(home.ptr);
        var i: usize = 0;
        while (candidates[i]) |candidate| : (i += 1) _ = execve(candidate, argv, envp);
        c._exit(127);
    }
    _ = setpgid(pid, pid);
    const leader = p.leaders.adopt(pid) catch {
        _ = c.kill(pid, .KILL);
        _ = c.waitpid(pid, null, 0);
        return error.SystemResources;
    };
    parent_done = true;
    s.leader = leader;
    s.fd = pipe[0];
    s.partial.clearRetainingCapacity();
    s.skipping = false;
}

/// Reads what the run wrote, without blocking, and handles each complete line.
fn drain(p: *Product, s: *Source) !void {
    if (s.fd < 0) return;
    var buf: [4096]u8 = undefined;
    for (0..16) |_| {
        const n = c.read(s.fd, &buf, buf.len);
        if (n < 0) switch (c.errno(n)) {
            .AGAIN, .INTR => return,
            else => {
                s.closeFd();
                return;
            },
        };
        if (n == 0) {
            s.closeFd();
            return;
        }
        try feed(p, s, buf[0..@intCast(n)]);
    }
}

fn feed(p: *Product, s: *Source, bytes: []const u8) !void {
    var rest = bytes;
    while (rest.len > 0) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        const chunk = rest[0 .. nl orelse rest.len];
        rest = if (nl) |k| rest[k + 1 ..] else &.{};
        if (!s.skipping) {
            if (s.partial.items.len + chunk.len > max_line) {
                // Lines are capped at 4096 bytes; a longer one is ignored.
                s.partial.clearRetainingCapacity();
                s.skipping = true;
            } else try s.partial.appendSlice(p.a, chunk);
        }
        if (nl == null) break;
        if (s.skipping) {
            s.skipping = false;
            continue;
        }
        try line(p, s, s.partial.items);
        s.partial.clearRetainingCapacity();
    }
}

fn line(p: *Product, s: *Source, raw: []const u8) !void {
    if (s.every() != null) {
        if (s.last_line) |x| p.a.free(x);
        s.last_line = null;
        s.last_line = try p.a.dupe(u8, raw);
    } else accept(p, s, raw);
}

/// A complete line: plain text, or JSON `{"text","style","icon"}` with each
/// field optional. An invalid line is ignored.
fn accept(p: *Product, s: *Source, raw: []const u8) void {
    const update = parseLine(p.a, raw) orelse return;
    defer update.deinit(p.a);
    if (update.text) |t| {
        const owned = p.a.dupe(u8, t) catch return;
        if (s.text) |x| p.a.free(x);
        s.text = owned;
    }
    if (update.style) |st| s.style = st;
    if (update.icon) |icon| {
        const owned = p.a.dupe(u8, icon) catch return;
        if (s.icon) |x| p.a.free(x);
        s.icon = owned;
    }
    s.dirty = true;
}

pub const Update = struct {
    text: ?[]const u8 = null,
    style: ?chrome.Style = null,
    icon: ?[]const u8 = null,
    parsed: ?std.json.Parsed(std.json.Value) = null,
    pub fn deinit(self: Update, a: std.mem.Allocator) void {
        _ = a;
        if (self.parsed) |x| x.deinit();
    }
};
/// Parses one line (without its newline). The text is cut at 256 bytes on
/// a character boundary.
pub fn parseLine(a: std.mem.Allocator, raw_line: []const u8) ?Update {
    const raw = std.mem.trimEnd(u8, raw_line, "\r");
    if (raw.len > 0 and raw[0] == '{') {
        const parsed = std.json.parseFromSlice(std.json.Value, a, raw, .{}) catch return null;
        var keep = false;
        defer if (!keep) parsed.deinit();
        if (parsed.value != .object) return null;
        const o = parsed.value.object;
        var out: Update = .{};
        if (o.get("text")) |v| {
            if (v != .string) return null;
            out.text = capText(v.string) orelse return null;
        }
        if (o.get("style")) |v| {
            if (v != .string) return null;
            out.style = std.meta.stringToEnum(chrome.Style, v.string) orelse return null;
        }
        if (o.get("icon")) |v| {
            if (v != .string or !chrome.validIcon(v.string)) return null;
            out.icon = v.string;
        }
        keep = true;
        out.parsed = parsed;
        return out;
    }
    return .{ .text = capText(raw) orelse return null };
}
fn capText(text: []const u8) ?[]const u8 {
    var n = @min(text.len, max_text);
    while (n > 0 and n < text.len and (text[n] & 0xc0) == 0x80) n -= 1;
    const cut = text[0..n];
    return if (chrome.validText(cut, 0, max_text)) cut else null;
}

fn publish(p: *Product, s: *Source, now: i64) !void {
    s.dirty = false;
    s.last_publish = now;
    const e = s.entry;
    try chrome.publish(p, .{
        .id = e.id,
        .text = s.text orelse "",
        .side = e.side orelse .right,
        .priority = e.priority orelse 50,
        .style = s.style orelse e.style orelse .normal,
        .when = e.when,
        // Exec segments are server-scoped and daemon-bound.
        .scope = "server",
        .bind = .daemon,
        .principal = proto.grants.owner,
        .group = e.group,
        .icon = s.icon orelse e.icon,
        .click = e.click,
        .origin = .exec,
    });
}

/// Sources whose last run failed, for `doctor`.
pub fn failing(p: *const Product) usize {
    var n: usize = 0;
    for (p.chrome.exec.items.items) |s| n += @intFromBool(s.last_failure != null);
    return n;
}

test "exec lines: plain text, JSON fields, caps and invalid lines" {
    const t = std.testing;
    const a = t.allocator;
    const plain = parseLine(a, "81%\r").?;
    defer plain.deinit(a);
    try t.expectEqualStrings("81%", plain.text.?);
    const json = parseLine(a, "{\"text\":\"wifi\",\"style\":\"warn\",\"icon\":\"W\"}").?;
    defer json.deinit(a);
    try t.expectEqualStrings("wifi", json.text.?);
    try t.expectEqual(chrome.Style.warn, json.style.?);
    try t.expectEqualStrings("W", json.icon.?);
    const only_style = parseLine(a, "{\"style\":\"ok\"}").?;
    defer only_style.deinit(a);
    try t.expect(only_style.text == null);
    try t.expect(parseLine(a, "{\"text\":1}") == null);
    try t.expect(parseLine(a, "{\"style\":\"loud\"}") == null);
    try t.expect(parseLine(a, "{broken") == null);
    try t.expect(parseLine(a, "bell\x07") == null);
    const long: [300]u8 = @splat('x');
    const cut = parseLine(a, &long).?;
    defer cut.deinit(a);
    try t.expectEqual(@as(usize, max_text), cut.text.?.len);
    try t.expect(validExec(.{ .argv = &.{"date"}, .every_ms = 1000 }));
    try t.expect(!validExec(.{ .argv = &.{"date"}, .every_ms = 999 }));
    try t.expect(!validExec(.{}));
}

/// `doctor`: exec sources whose last run failed.
pub fn doctor(r: *@import("cli").doctor.Report, p: *const Product) !void {
    const fix = try r.command("{s} config get --key status.segments --json", r.tool);
    var bad: std.ArrayList(u8) = .empty;
    for (p.chrome.exec.items.items) |s| if (s.last_failure) |f| {
        if (bad.items.len > 0) try bad.appendSlice(r.arena, ", ");
        const why = switch (f) {
            .exit => |code| try r.print("exit {d}", .{code}),
            .signal => |sig| try r.print("signal {d}", .{sig}),
            .overrun => "still running at the next interval",
            .spawn => "could not start",
        };
        try bad.print(r.arena, "{s} ({s}; {d} of {d} runs failed)", .{ s.entry.id, why, s.failed_runs, s.runs });
    };
    const n = p.chrome.exec.items.items.len;
    if (bad.items.len > 0) return r.add("status.exec", .warn, try r.print("exec sources: {d}; failing: {s}", .{ n, bad.items }), fix);
    try r.add("status.exec", .ok, try r.print("exec sources: {d}, none failing", .{n}), fix);
}

/// `config.set` of an `exec` entry in `status.segments` needs
/// the owner principal; any other admin gets `denied.owner` (exit 4). An
/// exec source runs a program as the daemon's user, like an `.exec` key
/// binding, so it comes only from the config files. Wraps the store's
/// `config.set` binding.
pub fn ExecGuard(comptime Store: type, comptime Config: type) type {
    return struct {
        store: *Store,
        pub fn call(self: *@This(), req: *proto.Call) anyerror!void {
            if (!try req.authorize(.admin, .{ .kind = "config", .id = "root" })) return;
            if (req.conn.identity.principal != proto.grants.owner) {
                const key = req.params.object.get("key").?.string;
                const value = req.params.object.get("value").?.string;
                const a = req.arena();
                const before = self.store.get(a, "status.segments") catch |err| if (err == error.OutOfMemory) return err else "";
                if (try setChangesExec(a, before, key, value, Config)) return req.fail("denied.owner", "only the owner principal adds, removes or changes an exec status source", .{ .key = key });
            }
            return self.store.call(req);
        }
    };
}

/// Whether `config.set` of `key` to `value` adds, removes or
/// changes an `exec` entry of `.status.segments`, given the effective
/// segments before (`before`, ZON). A value that does not parse is left to
/// the store to reject. Keys inside `status.segments` cannot be checked
/// entry by entry, so they count as a change whenever an exec entry exists
/// or the value mentions one.
pub fn setChangesExec(a: std.mem.Allocator, before_zon: []const u8, key: []const u8, value: []const u8, comptime Config: type) !bool {
    const touches = key.len == 0 or eq(u8, key, "status") or eq(u8, key, "status.segments") or std.mem.startsWith(u8, key, "status.segments.");
    if (!touches) return false;
    const before = parseSegments(a, before_zon) orelse return true;
    const after: []const chrome.SegmentEntry = if (key.len == 0)
        (parseZon(Config, a, value) catch return false).status.segments
    else if (eq(u8, key, "status"))
        (parseZon(chrome.StatusConfig, a, value) catch return false).segments
    else if (eq(u8, key, "status.segments"))
        parseZon([]const chrome.SegmentEntry, a, value) catch return false
    else
        return execCount(before) > 0 or std.mem.indexOf(u8, value, "exec") != null;
    return !try sameExec(a, before, after);
}
fn parseSegments(a: std.mem.Allocator, zon: []const u8) ?[]const chrome.SegmentEntry {
    return parseZon([]const chrome.SegmentEntry, a, zon) catch null;
}
/// Parses ZON into `a` (an arena).
fn parseZon(comptime T: type, a: std.mem.Allocator, text: []const u8) !T {
    const z = try a.dupeSentinel(u8, text, 0);
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    return std.zon.parse.fromSlice(T, .{ .gpa = a, .arena = a, .source = z, .diagnostics = &diagnostics });
}
fn execCount(entries: []const chrome.SegmentEntry) usize {
    var n: usize = 0;
    for (entries) |e| n += @intFromBool(e.exec != null);
    return n;
}
/// The same exec entries, compared whole, in any order.
fn sameExec(a: std.mem.Allocator, x: []const chrome.SegmentEntry, y: []const chrome.SegmentEntry) !bool {
    if (execCount(x) != execCount(y)) return false;
    for (x) |e| {
        if (e.exec == null) continue;
        const want = try entryKey(a, e);
        const found = for (y) |f| {
            if (f.exec != null and eq(u8, f.id, e.id) and eq(u8, try entryKey(a, f), want)) break true;
        } else false;
        if (!found) return false;
    }
    return true;
}
